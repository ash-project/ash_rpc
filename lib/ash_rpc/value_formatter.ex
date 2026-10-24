# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ValueFormatter do
  @moduledoc """
  Unified value formatting for RPC input/output.

  Traverses composite values recursively, applying field name mappings
  and type-aware formatting at each level. All type dispatch uses
  `%Ash.Info.Manifest.Type{}` exclusively — no raw Ash type atoms or
  `{:array, _}` tuples.

  ## Key Design Principle

  The "parent resource" is never needed because each type is self-describing.
  When we recurse into a nested value, we pass the sub-field's
  `%Ash.Info.Manifest.Type{}` which contains all type information needed.
  """

  alias Ash.Info.Manifest.Type
  alias AshRpc.{ClientNames, ClientPath, FieldFormatter, Introspection}
  alias AshRpc.Manifest.Custom

  @type direction :: :input | :output

  @doc """
  Formats a value based on its type.

  ## Parameters
  - `value` - The value to format
  - `type` - An `%Ash.Info.Manifest.Type{}`, `%Ash.Info.Manifest.Field{}`, `%Ash.Info.Manifest.Relationship{}`,
    a raw Ash type, or nil
  - `constraints` - Constraints for raw Ash types (ignored for manifest structs)
  - `direction` - `:input` (client→internal) or `:output` (internal→client)
  - `runtime` - The `AshRpc.Runtime` carrying the output formatter and lookups.
    `:output` names with the output formatter; `:input` resolves names with
    `AshRpc.ClientNames`.
  """
  @spec format(
          term(),
          Ash.Info.Manifest.Type.t()
          | Ash.Info.Manifest.Field.t()
          | Ash.Info.Manifest.Relationship.t()
          | atom()
          | tuple()
          | nil,
          keyword(),
          direction(),
          AshRpc.Runtime.t()
        ) :: term()
  def format(value, type, constraints, direction, rt) when direction in [:input, :output],
    do: do_format(value, type, constraints, rt.output_formatter, direction, rt)

  @typedoc "Why `format_input/3` rejected a value."
  @type input_error ::
          {:unknown_input, String.t(), [String.t() | non_neg_integer()]}
          | {:invalid_union_input, term()}
          | {:invalid_union_input, term(), term()}
          | {:invalid_union_input, term(), term(), term()}

  @doc """
  Formats one typed value as client input, with the rules RPC applies to an
  action input. Client names resolve by exact lookup, and every key of a node
  with decorated names must be one of them. Nodes without decorated names, and
  unconstrained maps, keep their keys as sent.

  Returns `{:ok, formatted}` or `{:error, reasons}`. The reasons are every
  `{:unknown_input, key, path}` miss in input order (`path` is relative to
  `value`: `[]` for a key directly in it), or the `:invalid_union_input`
  reason of a malformed union value. Never throws.
  """
  @spec format_input(term(), Type.t(), AshRpc.Runtime.t()) ::
          {:ok, term()} | {:error, [input_error()]}
  def format_input(value, %Type{} = type, rt) do
    {:ok, do_format(value, type, [], rt.output_formatter, :input, rt)}
  catch
    :throw, {:unknown_nested_input, reasons} ->
      {:error, reasons}

    :throw, reason when is_tuple(reason) and elem(reason, 0) == :invalid_union_input ->
      {:error, [reason]}
  end

  defp do_format(nil, _type, _constraints, _formatter, _direction, _rt), do: nil
  defp do_format(value, nil, _constraints, _formatter, _direction, _rt), do: value

  # %Ash.Info.Manifest.Field{} — extract type and delegate
  defp do_format(
         value,
         %Ash.Info.Manifest.Field{type: type},
         _constraints,
         formatter,
         direction,
         rt
       ) do
    do_format(value, type, [], formatter, direction, rt)
  end

  # Nested relationship pagination (output only): the value is the page map
  # produced by ResultProcessor.build_page_map/2 in the relationship position.
  # Dispatch is type-driven (Relationship + page-map shape), never heuristic
  # sniffing of arbitrary user maps.
  defp do_format(
         %{type: page_type, results: results} = page_map,
         %Ash.Info.Manifest.Relationship{destination: dest, cardinality: :many},
         _constraints,
         formatter,
         :output = direction,
         rt
       )
       when page_type in [:offset, :keyset] and not is_struct(page_map) do
    Enum.into(page_map, %{}, fn
      {:results, _} ->
        {FieldFormatter.format_field_name(:results, formatter),
         Enum.map(results, &format_resource(&1, dest, formatter, direction, rt))}

      {key, value} ->
        {FieldFormatter.format_field_name(key, formatter), value}
    end)
  end

  # %Ash.Info.Manifest.Relationship{} — format as resource
  defp do_format(
         value,
         %Ash.Info.Manifest.Relationship{destination: dest, cardinality: :many},
         _constraints,
         formatter,
         direction,
         rt
       ) do
    if is_list(value) do
      Enum.map(value, &format_resource(&1, dest, formatter, direction, rt))
    else
      value
    end
  end

  defp do_format(
         value,
         %Ash.Info.Manifest.Relationship{destination: dest},
         _constraints,
         formatter,
         direction,
         rt
       ) do
    format_resource(value, dest, formatter, direction, rt)
  end

  # %Ash.Info.Manifest.Type{} — primary dispatch, all type info is in the struct
  defp do_format(
         value,
         %Ash.Info.Manifest.Type{} = type_info,
         _constraints,
         formatter,
         direction,
         rt
       ) do
    case Introspection.classify_type(type_info, rt) do
      {:array, item_type} when is_list(value) and direction == :input ->
        input_items(value, &do_format(&1, item_type, [], formatter, :input, rt))

      {:array, item_type} when is_list(value) ->
        Enum.map(value, &do_format(&1, item_type, [], formatter, direction, rt))

      {:array, _item_type} ->
        value

      {:resource, resource} ->
        format_resource(value, resource, formatter, direction, rt)

      {:union, type} ->
        format_union(value, type, formatter, direction, rt)

      {_, %Type{kind: :tuple} = type} ->
        format_tuple(value, type, formatter, direction, rt)

      {_, %Type{kind: :keyword} = type} ->
        format_keyword(value, type, formatter, direction, rt)

      {:typed_struct, type} ->
        format_typed_fields(value, type, formatter, direction, rt)

      {:fields, type} ->
        if Type.has_fields?(type),
          do: format_typed_fields(value, type, formatter, direction, rt),
          else: value

      {:other, nil} ->
        value

      {:other, type} ->
        format_scalar(value, type, formatter, direction)
    end
  end

  # Raw Ash type atoms — resolve to %Ash.Info.Manifest.Type{} and dispatch
  defp do_format(value, type, constraints, formatter, direction, rt)
       when is_atom(type) and not is_nil(type) do
    resolved = Ash.Info.Manifest.Generator.TypeResolver.resolve(type, constraints)
    do_format(value, resolved, [], formatter, direction, rt)
  end

  # {:array, inner_type} tuple form — resolve to %Ash.Info.Manifest.Type{}
  defp do_format(value, {:array, inner_type}, constraints, formatter, direction, rt) do
    resolved = Ash.Info.Manifest.Generator.TypeResolver.resolve({:array, inner_type}, constraints)
    do_format(value, resolved, [], formatter, direction, rt)
  end

  # Catch-all for any unrecognized type — return value unchanged.
  defp do_format(value, _type, _constraints, _formatter, _direction, _rt), do: value

  # ---------------------------------------------------------------------------
  # Scalar Handler — vectors and custom map-storage types
  # ---------------------------------------------------------------------------

  defp format_scalar(value, %Type{module: Ash.Type.Vector}, _formatter, _direction),
    do: format_vector(value)

  defp format_scalar(value, %Type{module: module}, _formatter, :output)
       when is_map(value) and not is_struct(value) do
    if is_custom_type_with_map_storage?(module), do: stringify_keys(value), else: value
  end

  defp format_scalar(value, _type, _formatter, _direction), do: value

  defp is_custom_type_with_map_storage?(module) when is_atom(module) do
    Ash.Type.ash_type?(module) and
      Ash.Type.storage_type(module) == :map and
      not Ash.Type.builtin?(module)
  rescue
    _ -> false
  end

  # A custom map-storage type declares no field names, so its keys go out
  # as their string form, unformatted, and come in as sent.
  defp stringify_keys(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {stringify_key(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key), do: key

  # `%Ash.Vector{}` keeps its floats in a packed binary, which is not
  # JSON-encodable, so the wire format has to be a plain list of numbers. Result extraction
  # already ran `Map.from_struct/1` by the time formatting runs, hence the second
  # clause; `from_binary/1` recovers the dimensions from the binary header.
  # Inbound values arrive as lists and fall through untouched, since
  # `Ash.Type.Vector.cast_input/2` accepts a list.
  defp format_vector(%Ash.Vector{} = vector), do: Ash.Vector.to_list(vector)

  defp format_vector(%{data: data}) when is_binary(data) do
    data |> Ash.Vector.from_binary() |> Ash.Vector.to_list()
  end

  defp format_vector(other), do: other

  # ---------------------------------------------------------------------------
  # Resource Handler
  # ---------------------------------------------------------------------------

  defp format_resource(value, resource, formatter, direction, rt)

  defp format_resource(value, resource, formatter, :input, rt)
       when is_map(value) and not is_struct(value) do
    strict? = ClientNames.resource_named?(rt, resource)

    input_entries(
      value,
      &input_key(ClientNames.resource_field(rt, resource, &1), &1, strict?),
      fn field, field_value ->
        field_or_rel =
          Ash.Info.Manifest.get_field_or_relationship(rt.resource_lookup, resource, field)

        do_format(field_value, field_or_rel, [], formatter, :input, rt)
      end
    )
  end

  defp format_resource(value, resource, formatter, :output, rt)
       when is_map(value) and not is_struct(value) do
    res_struct = Map.get(rt.resource_lookup, resource)

    Enum.into(value, %{}, fn {key, field_value} ->
      # A string key is a read action's metadata override, not a field, so
      # its value passes through.
      field_or_rel =
        if is_atom(key),
          do: Ash.Info.Manifest.get_field_or_relationship(rt.resource_lookup, resource, key)

      formatted_value = do_format(field_value, field_or_rel, [], formatter, :output, rt)
      {resource_output_key(key, res_struct, formatter), formatted_value}
    end)
  end

  defp format_resource(value, _resource, _formatter, _direction, _rt), do: value

  # Extracted records carry atom keys; a string key is already a client name
  # (a read action's metadata override) and goes out as-is.
  defp resource_output_key(key, _res_struct, _formatter) when is_binary(key), do: key

  defp resource_output_key(key, res_struct, formatter),
    do: FieldFormatter.format_field_for_client(key, res_struct, formatter)

  # ---------------------------------------------------------------------------
  # Strict input keys
  # ---------------------------------------------------------------------------
  #
  # Every map level resolves all of its keys and formats every value, then
  # throws `{:unknown_nested_input, reasons}` for all misses at or below it,
  # each `{:unknown_input, key, path}` with the path relative to the value.
  # Each parent prepends its own key (or array index). A node without
  # decorated names keeps its keys as sent and leaves them to Ash.

  defp input_key({:ok, field}, _key, _strict?), do: {:ok, field}
  defp input_key(:error, _key, true), do: :error
  defp input_key(:error, key, false), do: {:ok, key}

  defp input_entries(map, resolve, format_entry) do
    {entries, misses} =
      Enum.reduce(map, {[], []}, fn {key, value}, {entries, misses} ->
        with {:ok, field} <- resolve.(key),
             {:ok, formatted} <- collect_input(key, fn -> format_entry.(field, value) end) do
          {[{field, formatted} | entries], misses}
        else
          :error -> {entries, [{:unknown_input, key, []} | misses]}
          {:misses, nested} -> {entries, Enum.reverse(nested, misses)}
        end
      end)

    throw_input_misses(misses)
    Map.new(entries)
  end

  @doc false
  # Formats each list item with `format_item`, collecting nested input misses
  # under each item's index.
  def input_items(items, format_item) do
    {items, misses} =
      items
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, index}, {items, misses} ->
        case collect_input(index, fn -> format_item.(item) end) do
          {:ok, formatted} -> {[formatted | items], misses}
          {:misses, nested} -> {items, Enum.reverse(nested, misses)}
        end
      end)

    throw_input_misses(misses)
    Enum.reverse(items)
  end

  defp throw_input_misses([]), do: :ok
  defp throw_input_misses(misses), do: throw({:unknown_nested_input, Enum.reverse(misses)})

  @doc false
  # Runs `fun` for the input value under `segment`. Its nested input misses
  # come back as `{:misses, reasons}` with `segment` prepended to each path.
  @spec collect_input(String.t() | atom() | non_neg_integer(), (-> term())) ::
          {:ok, term()} | {:misses, list()}
  def collect_input(segment, fun) do
    {:ok, fun.()}
  catch
    :throw, {:unknown_nested_input, reasons} ->
      {:misses,
       Enum.map(reasons, fn {:unknown_input, key, path} ->
         {:unknown_input, key, [segment | path]}
       end)}
  end

  # ---------------------------------------------------------------------------
  # Typed Fields Handler — typed structs, typed maps, keywords and tuples
  # ---------------------------------------------------------------------------

  defp format_typed_fields(value, type_info, formatter, :input, rt) when is_map(value),
    do: typed_input(value, type_info, formatter, rt)

  defp format_typed_fields(value, type_info, formatter, :output, rt) when is_map(value),
    do: declared_output(value, type_info, formatter, rt)

  defp format_typed_fields(value, _type_info, _formatter, _direction, _rt), do: value

  # Typed structs, typed maps, keywords and tuples share strict key input.
  defp typed_input(value, type_info, formatter, rt) do
    strict? = ClientNames.type_named?(rt, type_info)

    input_entries(
      value,
      &input_key(ClientNames.type_field(rt, type_info, &1), &1, strict?),
      fn field, field_value ->
        do_format(field_value, Type.find_field_type(type_info, field), [], formatter, :input, rt)
      end
    )
  end

  # Output of a typed struct, typed map, keyword or tuple: only the value's
  # entries whose key is a declared field (the atom or its string form) come
  # out, each formatted with that field's type. Everything else is dropped, so
  # a struct's undeclared keys never reach a client. Names come from
  # decoration (the override pair, then the decorated names). Only a container
  # no decoration reached falls back to the formatter, over the declared
  # field's name, never over a value key.
  defp declared_output(value, type_info, formatter, rt) do
    map = if is_struct(value), do: Map.from_struct(value), else: value
    fields = Type.get_fields(type_info)
    overrides = name_overrides(type_info, rt)
    names = type_info |> ClientPath.decorated_type(rt) |> Custom.type_field_names()

    for {key, field_value} <- map, field = declared_field(fields, key), into: %{} do
      name =
        Map.get(overrides, field.name) || Map.get(names, field.name) ||
          FieldFormatter.format_field_name(field.name, formatter)

      {name, do_format(field_value, field.type, [], formatter, :output, rt)}
    end
  end

  defp declared_field(fields, key) when is_atom(key), do: Enum.find(fields, &(&1.name == key))

  defp declared_field(fields, key) when is_binary(key),
    do: Enum.find(fields, &(Atom.to_string(&1.name) == key))

  defp declared_field(_fields, _key), do: nil

  # Returns the forward client field-name overrides for a typed container,
  # preferring the decoration on the struct in hand. Undecorated types (e.g. some
  # `action.returns` structs) resolve through the type lookup and then the
  # mapping source (`AshRpc.Introspection.type_field_name_overrides/2`).
  defp name_overrides(type_info, rt) do
    case Custom.type_field_name_overrides_pair(type_info) do
      nil -> Introspection.type_field_name_overrides(rt, Type.effective_module(type_info)) || %{}
      {forward, _reverse} -> forward
    end
  end

  # ---------------------------------------------------------------------------
  # Tuple Handler
  # ---------------------------------------------------------------------------

  defp format_tuple(value, type_info, formatter, direction, rt)
       when is_tuple(value) do
    fields = Type.get_fields(type_info)

    # Convert tuple to map using field names as keys
    map_value =
      case fields do
        [%{name: _} | _] ->
          fields
          |> Enum.with_index()
          |> Enum.into(%{}, fn {field, index} ->
            {field.name, elem(value, index)}
          end)

        _ ->
          %{}
      end

    format_container(map_value, type_info, formatter, direction, rt)
  end

  defp format_tuple(value, type_info, formatter, direction, rt)
       when is_map(value) do
    format_container(value, type_info, formatter, direction, rt)
  end

  defp format_tuple(value, _type_info, _formatter, _direction, _rt), do: value

  # ---------------------------------------------------------------------------
  # Keyword Handler
  # ---------------------------------------------------------------------------

  defp format_keyword(value, type_info, formatter, direction, rt)
       when is_list(value) do
    map_value = Enum.into(value, %{})
    format_container(map_value, type_info, formatter, direction, rt)
  end

  defp format_keyword(value, type_info, formatter, direction, rt)
       when is_map(value) do
    format_container(value, type_info, formatter, direction, rt)
  end

  defp format_keyword(value, _type_info, _formatter, _direction, _rt), do: value

  # A keyword or tuple (as a map) with fields is formatted like any typed map;
  # without fields it passes through like an unconstrained map.
  defp format_container(map_value, type_info, formatter, direction, rt) do
    if Type.has_fields?(type_info),
      do: format_typed_fields(map_value, type_info, formatter, direction, rt),
      else: map_value
  end

  # ---------------------------------------------------------------------------
  # Union Handler
  # ---------------------------------------------------------------------------

  defp format_union(value, type_info, formatter, direction, rt) do
    storage_type = Keyword.get(type_info.constraints || [], :storage)

    case direction do
      :input ->
        format_union_input(value, type_info, formatter, rt)

      :output ->
        format_union_output(value, type_info.members || [], storage_type, formatter, rt)
    end
  end

  defp format_union_input(value, type_info, formatter, rt) do
    members = type_info.members || []

    case identify_union_member_spec(value, members, type_info, rt) do
      {:ok, member} ->
        client_key = find_client_key_for_member(value, member.name, type_info, rt)

        formatted =
          case collect_input(client_key, fn ->
                 do_format(Map.get(value, client_key), member.type, [], formatter, :input, rt)
               end) do
            {:ok, formatted} -> formatted
            {:misses, reasons} -> throw({:unknown_nested_input, reasons})
          end

        maybe_inject_tag(formatted, member)

      {:error, error} ->
        throw(error)
    end
  end

  defp format_union_output(value, members, storage_type, formatter, rt) do
    case find_union_member_spec(value, members) do
      %{} = member ->
        member_data =
          extract_union_member_data_spec(value, member, storage_type, formatter, rt)

        formatted_member_value =
          do_format(member_data, member.type, [], formatter, :output, rt)

        formatted_member_name = FieldFormatter.format_field_name(member.name, formatter)
        %{formatted_member_name => formatted_member_value}

      nil ->
        %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Union Helper Functions
  # ---------------------------------------------------------------------------

  # Identify which union member matches the input (spec members version)
  defp identify_union_member_spec(%{} = map, members, type_info, rt) do
    case identify_tagged_union_member_spec(map, members, rt) do
      {:ok, member} -> {:ok, member}
      :not_found -> identify_key_based_union_member_spec(map, members, type_info, rt)
    end
  end

  defp identify_union_member_spec(_value, _members, _type_info, _rt),
    do: {:error, {:invalid_union_input, :not_a_map}}

  defp identify_tagged_union_member_spec(map, members, rt) do
    case Enum.find(members, fn member ->
           tag_field = Map.get(member, :tag)

           tag_field != nil and
             has_matching_tag?(map, tag_field, Map.get(member, :tag_value), member.type, rt)
         end) do
      nil -> :not_found
      member -> {:ok, member}
    end
  end

  defp identify_key_based_union_member_spec(map, members, type_info, rt) do
    member_names =
      Enum.map(
        members,
        &FieldFormatter.format_field_name(to_string(&1.name), rt.output_formatter)
      )

    matching_members =
      Enum.filter(members, fn member ->
        Enum.any?(
          Map.keys(map),
          &(ClientNames.union_member(rt, type_info, &1) == {:ok, member.name})
        )
      end)

    case matching_members do
      [] ->
        {:error, {:invalid_union_input, :no_member_key, member_names}}

      [single_member] ->
        {:ok, single_member}

      multiple_members ->
        found_keys =
          Enum.map(
            multiple_members,
            &FieldFormatter.format_field_name(to_string(&1.name), rt.output_formatter)
          )

        {:error, {:invalid_union_input, :multiple_member_keys, found_keys, member_names}}
    end
  end

  defp has_matching_tag?(map, tag_field, tag_value, member_type, rt) do
    Enum.any?(map, fn {key, value} ->
      tag_key(rt, member_type, key) == {:ok, tag_field} and value == tag_value
    end)
  end

  # An embedded-resource member names its tag attribute on the resource, not
  # as a type field.
  defp tag_key(rt, %Type{} = member_type, key) do
    if Type.resource_kind?(member_type),
      do: ClientNames.resource_field(rt, Type.effective_resource(member_type), key),
      else: ClientNames.type_field(rt, member_type, key)
  end

  defp find_client_key_for_member(map, member_name, type_info, rt) do
    Enum.find(Map.keys(map), &(ClientNames.union_member(rt, type_info, &1) == {:ok, member_name}))
  end

  # Find union member for output (matches on map keys by member name)
  defp find_union_member_spec(data, members) do
    map_keys = MapSet.new(Map.keys(data))
    Enum.find(members, fn member -> MapSet.member?(map_keys, member.name) end)
  end

  defp extract_union_member_data_spec(data, member, storage_type, formatter, rt) do
    case storage_type do
      :type_and_value ->
        data[member.name]

      :map_with_tag ->
        tag_field = Map.get(member, :tag)
        member_data = data[member.name]

        if tag_field && is_map(member_data) && Map.has_key?(member_data, tag_field) &&
             not member_names_field?(rt, member.type, tag_field) do
          # The member type carries no decorated name for its tag: the formatter names it.
          tag_value = Map.get(member_data, tag_field)
          formatted_tag_field = FieldFormatter.format_field_name(tag_field, formatter)

          member_data
          |> Map.delete(tag_field)
          |> Map.put(formatted_tag_field, tag_value)
        else
          member_data
        end

      _ ->
        data[member.name]
    end
  end

  # The member's own formatting names every field it declares, overrides
  # included; only an undeclared tag field needs the formatter here.
  defp member_names_field?(rt, %Type{} = member_type, field) do
    names =
      if Type.resource_kind?(member_type),
        do:
          rt.resource_lookup
          |> Map.get(Type.effective_resource(member_type))
          |> Custom.field_names(),
        else: member_type |> ClientPath.decorated_type(rt) |> Custom.type_field_names()

    Map.has_key?(names, field)
  end

  defp member_names_field?(_rt, _member_type, _field), do: false

  defp maybe_inject_tag(formatted_value, member) when is_map(formatted_value) do
    tag_field = Map.get(member, :tag)
    tag_value = Map.get(member, :tag_value)

    if tag_field && tag_value do
      Map.put(formatted_value, tag_field, tag_value)
    else
      formatted_value
    end
  end

  defp maybe_inject_tag(value, _member), do: value
end
