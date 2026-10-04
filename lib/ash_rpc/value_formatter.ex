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
  alias AshRpc.{FieldFormatter, Introspection}
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
  - `runtime` - The `AshRpc.Runtime` carrying formatters and lookups. The
    input formatter is used for `:input`, the output formatter for `:output`.
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
  def format(value, type, constraints, :input, rt),
    do: do_format(value, type, constraints, rt.input_formatter, :input, rt)

  def format(value, type, constraints, :output, rt),
    do: do_format(value, type, constraints, rt.output_formatter, :output, rt)

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
        format_typed_struct(value, type, formatter, direction, rt)

      {:fields, type} ->
        if Type.has_fields?(type),
          do: format_typed_map(value, type, formatter, direction, rt),
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

  defp format_scalar(value, %Type{module: module}, formatter, direction)
       when is_map(value) and not is_struct(value) do
    if is_custom_type_with_map_storage?(module),
      do: format_map_keys_only(value, formatter, direction),
      else: value
  end

  defp format_scalar(value, _type, _formatter, _direction), do: value

  defp is_custom_type_with_map_storage?(module) when is_atom(module) do
    Ash.Type.ash_type?(module) and
      Ash.Type.storage_type(module) == :map and
      not Ash.Type.builtin?(module)
  rescue
    _ -> false
  end

  defp format_map_keys_only(map, formatter, :output) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      string_key = FieldFormatter.format_field_name(key, formatter)

      formatted_value =
        case value do
          nested_map when is_map(nested_map) and not is_struct(nested_map) ->
            format_map_keys_only(nested_map, formatter, :output)

          list when is_list(list) ->
            Enum.map(list, fn item ->
              if is_map(item) and not is_struct(item) do
                format_map_keys_only(item, formatter, :output)
              else
                item
              end
            end)

          other ->
            other
        end

      {string_key, formatted_value}
    end)
  end

  defp format_map_keys_only(map, formatter, :input) when is_map(map) do
    Enum.into(map, %{}, fn {key, value} ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)

      formatted_value =
        case value do
          nested_map when is_map(nested_map) and not is_struct(nested_map) ->
            format_map_keys_only(nested_map, formatter, :input)

          list when is_list(list) ->
            Enum.map(list, fn item ->
              if is_map(item) and not is_struct(item) do
                format_map_keys_only(item, formatter, :input)
              else
                item
              end
            end)

          other ->
            other
        end

      {internal_key, formatted_value}
    end)
  end

  defp format_map_keys_only(value, _formatter, _direction), do: value

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

  defp format_resource(value, resource, formatter, direction, rt)
       when is_map(value) and not is_struct(value) do
    res_struct = Map.get(rt.resource_lookup, resource)

    Enum.into(value, %{}, fn {key, field_value} ->
      internal_key = convert_resource_key(key, res_struct, formatter, direction)

      # Look up field or relationship from the spec directly
      field_or_rel =
        Ash.Info.Manifest.get_field_or_relationship(rt.resource_lookup, resource, internal_key)

      formatted_value =
        do_format(field_value, field_or_rel, [], formatter, direction, rt)

      output_key =
        case direction do
          :input -> internal_key
          :output -> FieldFormatter.format_field_for_client(internal_key, res_struct, formatter)
        end

      {output_key, formatted_value}
    end)
  end

  defp format_resource(value, _resource, _formatter, _direction, _rt), do: value

  defp convert_resource_key(key, res_struct, formatter, :input) when is_binary(key) do
    case Custom.original_field_name(res_struct, key) do
      original when is_atom(original) and not is_nil(original) -> original
      _ -> FieldFormatter.parse_input_field(key, formatter)
    end
  end

  defp convert_resource_key(key, _res_struct, _formatter, :input), do: key
  defp convert_resource_key(key, _res_struct, _formatter, :output), do: key

  # ---------------------------------------------------------------------------
  # TypedStruct Handler — struct types with field constraints
  # ---------------------------------------------------------------------------

  defp format_typed_struct(value, type_info, formatter, direction, rt)
       when is_map(value) do
    {field_names, reverse_map} = typed_struct_field_maps(type_info, rt)

    Enum.into(value, %{}, fn {key, field_value} ->
      internal_key = convert_typed_struct_key(key, reverse_map, formatter, direction)

      sub_type = Type.find_field_type(type_info, internal_key)

      formatted_value =
        do_format(field_value, sub_type, [], formatter, direction, rt)

      output_key =
        case direction do
          :input -> internal_key
          :output -> get_typed_struct_output_key(internal_key, field_names, formatter)
        end

      {output_key, formatted_value}
    end)
  end

  defp format_typed_struct(value, _type_info, _formatter, _direction, _rt),
    do: value

  defp convert_typed_struct_key(key, reverse_map, formatter, :input) when is_binary(key) do
    case Map.get(reverse_map, key) do
      nil -> FieldFormatter.parse_input_field(key, formatter)
      internal -> internal
    end
  end

  defp convert_typed_struct_key(key, _reverse_map, _formatter, _direction), do: key

  defp get_typed_struct_output_key(internal_key, field_names, formatter) do
    case Map.get(field_names, internal_key) do
      nil -> FieldFormatter.format_field_name(internal_key, formatter)
      client_name -> client_name
    end
  end

  # Returns `{forward, reverse}` client field-name maps for a typed struct,
  # preferring the decoration on the struct in hand. Undecorated types (e.g. some
  # `action.returns` structs) resolve through the type lookup and then the
  # mapping source (`AshRpc.Introspection.type_field_name_overrides/2`).
  defp typed_struct_field_maps(type_info, rt) do
    case Custom.type_field_name_overrides_pair(type_info) do
      nil ->
        forward =
          Introspection.type_field_name_overrides(rt, Type.effective_module(type_info)) || %{}

        {forward, Map.new(forward, fn {k, v} -> {v, k} end)}

      pair ->
        pair
    end
  end

  # ---------------------------------------------------------------------------
  # Typed Map Handler — types with field constraints but no field name mapping
  # ---------------------------------------------------------------------------

  defp format_typed_map(value, type_info, formatter, direction, rt)
       when is_map(value) do
    fields = Type.get_fields(type_info)

    if fields == [] do
      value
    else
      Enum.into(value, %{}, fn {key, field_value} ->
        internal_key =
          case direction do
            :input -> FieldFormatter.parse_input_field(key, formatter)
            :output -> key
          end

        sub_type = Type.find_field_type(type_info, internal_key)

        formatted_value =
          do_format(field_value, sub_type, [], formatter, direction, rt)

        output_key =
          case direction do
            :input -> internal_key
            :output -> FieldFormatter.format_field_name(internal_key, formatter)
          end

        {output_key, formatted_value}
      end)
    end
  end

  defp format_typed_map(value, _type_info, _formatter, _direction, _rt), do: value

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

    dispatch_struct_or_map(map_value, type_info, formatter, direction, rt)
  end

  defp format_tuple(value, type_info, formatter, direction, rt)
       when is_map(value) do
    dispatch_struct_or_map(value, type_info, formatter, direction, rt)
  end

  defp format_tuple(value, _type_info, _formatter, _direction, _rt), do: value

  # ---------------------------------------------------------------------------
  # Keyword Handler
  # ---------------------------------------------------------------------------

  defp format_keyword(value, type_info, formatter, direction, rt)
       when is_list(value) do
    map_value = Enum.into(value, %{})
    dispatch_struct_or_map(map_value, type_info, formatter, direction, rt)
  end

  defp format_keyword(value, type_info, formatter, direction, rt)
       when is_map(value) do
    dispatch_struct_or_map(value, type_info, formatter, direction, rt)
  end

  defp format_keyword(value, _type_info, _formatter, _direction, _rt), do: value

  # Shared: dispatch to typed_struct (if has field name mapping) or typed_map
  defp dispatch_struct_or_map(map_value, type_info, formatter, direction, rt) do
    inst = Type.effective_module(type_info)

    if Introspection.has_field_name_overrides?(rt, inst) do
      format_typed_struct(map_value, type_info, formatter, direction, rt)
    else
      format_typed_map(map_value, type_info, formatter, direction, rt)
    end
  end

  # ---------------------------------------------------------------------------
  # Union Handler
  # ---------------------------------------------------------------------------

  defp format_union(value, type_info, formatter, direction, rt) do
    members = type_info.members || []
    storage_type = Keyword.get(type_info.constraints || [], :storage)

    case direction do
      :input ->
        format_union_input(value, members, formatter, rt)

      :output ->
        format_union_output(value, members, storage_type, formatter, rt)
    end
  end

  defp format_union_input(value, members, formatter, rt) do
    case identify_union_member_spec(value, members, formatter, rt) do
      {:ok, member} ->
        client_key = find_client_key_for_member(value, member.name, formatter)
        member_value = Map.get(value, client_key)

        formatted_value =
          do_format(member_value, member.type, [], formatter, :input, rt)

        maybe_inject_tag(formatted_value, member)

      {:error, error} ->
        throw(error)
    end
  end

  defp format_union_output(value, members, storage_type, formatter, rt) do
    case find_union_member_spec(value, members) do
      %{} = member ->
        member_data =
          extract_union_member_data_spec(value, member, storage_type, formatter)

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
  defp identify_union_member_spec(%{} = map, members, formatter, rt) do
    case identify_tagged_union_member_spec(map, members, formatter) do
      {:ok, member} -> {:ok, member}
      :not_found -> identify_key_based_union_member_spec(map, members, formatter, rt)
    end
  end

  defp identify_union_member_spec(_value, _members, _formatter, _rt) do
    {:error, {:invalid_union_input, :not_a_map}}
  end

  defp identify_tagged_union_member_spec(map, members, formatter) do
    case Enum.find(members, fn member ->
           tag_field = Map.get(member, :tag)
           tag_value = Map.get(member, :tag_value)

           tag_field != nil and
             has_matching_tag?(map, tag_field, tag_value, formatter)
         end) do
      nil -> :not_found
      member -> {:ok, member}
    end
  end

  defp identify_key_based_union_member_spec(map, members, formatter, rt) do
    output_formatter = rt.output_formatter

    member_names =
      Enum.map(members, fn m ->
        FieldFormatter.format_field_name(to_string(m.name), output_formatter)
      end)

    matching_members =
      Enum.filter(members, fn member ->
        Enum.any?(Map.keys(map), fn client_key ->
          internal_key = FieldFormatter.parse_input_field(client_key, formatter)
          to_string(internal_key) == to_string(member.name)
        end)
      end)

    case matching_members do
      [] ->
        {:error, {:invalid_union_input, :no_member_key, member_names}}

      [single_member] ->
        {:ok, single_member}

      multiple_members ->
        found_keys =
          Enum.map(multiple_members, fn m ->
            FieldFormatter.format_field_name(to_string(m.name), output_formatter)
          end)

        {:error, {:invalid_union_input, :multiple_member_keys, found_keys, member_names}}
    end
  end

  defp has_matching_tag?(map, tag_field, tag_value, formatter) do
    Enum.any?(map, fn {key, value} ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)
      internal_key == tag_field && value == tag_value
    end)
  end

  defp find_client_key_for_member(map, member_name, formatter) do
    Enum.find(Map.keys(map), fn key ->
      internal_key = FieldFormatter.parse_input_field(key, formatter)
      internal_key == member_name or to_string(internal_key) == to_string(member_name)
    end)
  end

  # Find union member for output (matches on map keys by member name)
  defp find_union_member_spec(data, members) do
    map_keys = MapSet.new(Map.keys(data))
    Enum.find(members, fn member -> MapSet.member?(map_keys, member.name) end)
  end

  defp extract_union_member_data_spec(data, member, storage_type, formatter) do
    case storage_type do
      :type_and_value ->
        data[member.name]

      :map_with_tag ->
        tag_field = Map.get(member, :tag)
        member_data = data[member.name]

        if tag_field && is_map(member_data) && Map.has_key?(member_data, tag_field) do
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
