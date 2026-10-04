# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ResultProcessor do
  @moduledoc """
  Extracts requested fields from RPC results using type-driven dispatch.

  All type dispatch uses `%Ash.Info.Manifest.Type{}` — no raw Ash type atoms or
  `{:array, _}` tuples in the primary dispatch path.

  ## Type-Driven Extraction

  ```
  extract_value/5 (unified type-driven dispatch)
     │
     ├─> extract_resource_value/4    (Ash Resources)
     ├─> extract_typed_struct_value/4 (TypedStruct/NewType with field name mapping)
     ├─> extract_typed_map_value/4   (Map/Struct/Tuple/Keyword with fields)
     ├─> extract_union_value/4       (Ash.Type.Union)
     ├─> extract_array_value/5       (Arrays - recurse)
     └─> normalize_primitive/2       (Primitives)
  ```
  """

  alias Ash.Info.Manifest.Type
  alias AshRpc.{FieldExtractor, Introspection}

  @doc """
  Main entry point for processing Ash results.
  """
  @spec process(term(), map() | list(), module() | nil, AshRpc.Runtime.t()) :: term()
  def process(result, extraction_template, resource, rt) do
    case result do
      %Ash.Page.Offset{results: results} = page ->
        build_page_map(
          page,
          extract_list_fields(results, extraction_template, resource, rt)
        )

      %Ash.Page.Keyset{results: results} = page ->
        build_page_map(
          page,
          extract_list_fields(results, extraction_template, resource, rt)
        )

      [] ->
        []

      result when is_list(result) ->
        if Keyword.keyword?(result) do
          extract_single_result(result, extraction_template, resource, rt)
        else
          extract_list_fields(result, extraction_template, resource, rt)
        end

      result ->
        extract_single_result(result, extraction_template, resource, rt)
    end
  end

  @doc """
  Shapes an `%Ash.Page.Offset{}`/`%Ash.Page.Keyset{}` into the client page map.
  Used for both top-level pagination and nested relationship pagination so the
  shapes are identical by construction. Keyset cursors are nil on empty pages.
  """
  def build_page_map(%Ash.Page.Offset{} = page, processed_results) do
    page
    |> Map.take([:limit, :offset, :count])
    |> Map.put(:results, processed_results)
    |> Map.put(:has_more, page.more? || false)
    |> Map.put(:type, :offset)
  end

  def build_page_map(%Ash.Page.Keyset{results: results} = page, processed_results) do
    {previous_page_cursor, next_page_cursor} =
      if Enum.empty?(results) do
        {nil, nil}
      else
        {List.first(results).__metadata__.keyset, List.last(results).__metadata__.keyset}
      end

    page
    |> Map.take([:before, :after, :limit, :count])
    |> Map.put(:has_more, page.more? || false)
    |> Map.put(:results, processed_results)
    |> Map.put(:previous_page, previous_page_cursor)
    |> Map.put(:next_page, next_page_cursor)
    |> Map.put(:type, :keyset)
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Unified Type Lookup
  # ─────────────────────────────────────────────────────────────────────────────

  @spec get_field_or_relationship(module() | nil, atom(), map() | nil) ::
          Ash.Info.Manifest.Field.t() | Ash.Info.Manifest.Relationship.t() | nil
  def get_field_or_relationship(nil, _field_name, _lookups), do: nil

  def get_field_or_relationship(resource, field_name, rt)
      when is_atom(resource) and is_map(rt) do
    Ash.Info.Manifest.get_field_or_relationship(rt.resource_lookup, resource, field_name)
  end

  def get_field_or_relationship(_resource, _field_name, _lookups), do: nil

  # ─────────────────────────────────────────────────────────────────────────────
  # Type-Driven Extraction Dispatcher
  # ─────────────────────────────────────────────────────────────────────────────

  @spec extract_value(
          term(),
          atom() | tuple() | Ash.Info.Manifest.Type.t() | nil,
          keyword(),
          list(),
          map() | nil
        ) :: term()
  def extract_value(value, type, constraints, template, rt)

  def extract_value(nil, _type, _constraints, _template, _rt), do: nil

  def extract_value(%Ash.ForbiddenField{}, _type, _constraints, _template, _rt),
    do: nil

  def extract_value(%Ash.NotLoaded{}, _type, _constraints, _template, _rt),
    do: :skip

  # %Ash.Info.Manifest.Field{} — extract type and delegate
  def extract_value(
        value,
        %Ash.Info.Manifest.Field{type: type},
        _constraints,
        template,
        rt
      ) do
    extract_value(value, type, [], template, rt)
  end

  # Nested relationship pagination: the relationship value is a page struct.
  def extract_value(
        %page_struct{} = page,
        %Ash.Info.Manifest.Relationship{destination: dest, cardinality: :many},
        _constraints,
        template,
        rt
      )
      when page_struct in [Ash.Page.Offset, Ash.Page.Keyset] do
    processed =
      extract_array_value(
        page.results,
        %Ash.Info.Manifest.Type{kind: :resource, module: dest, resource_module: dest},
        template,
        rt
      )

    build_page_map(page, processed)
  end

  # %Ash.Info.Manifest.Relationship{} — delegate to resource/array handler
  def extract_value(
        value,
        %Ash.Info.Manifest.Relationship{destination: dest, cardinality: :many},
        _constraints,
        template,
        rt
      ) do
    extract_array_value(
      value,
      %Ash.Info.Manifest.Type{kind: :resource, module: dest, resource_module: dest},
      template,
      rt
    )
  end

  def extract_value(
        value,
        %Ash.Info.Manifest.Relationship{destination: dest},
        _constraints,
        template,
        rt
      ) do
    extract_resource_value(value, dest, template, rt)
  end

  # nil/unknown types
  def extract_value(value, nil, _constraints, template, rt)
      when is_map(value) and template != [] do
    extract_plain_map_value(value, template, rt)
  end

  def extract_value(value, nil, _constraints, _template, rt),
    do: normalize_primitive(value, rt)

  # %Ash.Info.Manifest.Type{} — primary dispatch
  def extract_value(
        value,
        %Ash.Info.Manifest.Type{} = type_info,
        _constraints,
        template,
        rt
      ) do
    inst = Type.effective_module(type_info)

    case type_info.kind do
      :type_ref ->
        full_type = Ash.Info.Manifest.get_type!(rt.type_lookup, type_info.module)
        extract_value(value, full_type, [], template, rt)

      :array ->
        extract_array_value(value, type_info.item_type, template, rt)

      kind when kind in [:resource, :embedded_resource] ->
        resource = Type.effective_resource(type_info)
        extract_resource_value(value, resource, template, rt)

      :union ->
        extract_union_value(value, type_info, template, rt)

      kind when kind in [:struct, :map] ->
        cond do
          inst && is_atom(inst) && Introspection.ash_resource?(inst) ->
            extract_resource_value(value, inst, template, rt)

          has_field_name_overrides?(rt, inst) ->
            extract_typed_struct_value(value, type_info, template, rt)

          true ->
            extract_typed_map_value(value, type_info, template, rt)
        end

      kind when kind in [:tuple, :keyword] ->
        if has_field_name_overrides?(rt, inst) do
          extract_typed_struct_value(value, type_info, template, rt)
        else
          extract_typed_map_value(value, type_info, template, rt)
        end

      _ ->
        normalize_primitive(value, rt)
    end
  end

  # Catch-all for unrecognized types
  def extract_value(value, _type, _constraints, _template, rt),
    do: normalize_primitive(value, rt)

  # (Type checking helpers are in AshRpc.Introspection and Ash.Info.Manifest.Type)

  # ─────────────────────────────────────────────────────────────────────────────
  # Type-Specific Handlers
  # ─────────────────────────────────────────────────────────────────────────────

  # Resource Handler
  defp extract_resource_value(value, resource, template, rt) when is_map(value) do
    value_is_resource_instance =
      is_struct(value) && value.__struct__ == resource

    if value_is_resource_instance do
      if template == [] do
        normalize_resource_struct(value, resource, rt)
      else
        normalized = FieldExtractor.normalize_for_extraction(value, template)

        Enum.reduce(template, %{}, fn field_spec, acc ->
          case field_spec do
            field_atom when is_atom(field_atom) ->
              extract_resource_field(normalized, resource, field_atom, acc, rt)

            {field_atom, nested_template} when is_atom(field_atom) ->
              extract_resource_nested_field(
                normalized,
                resource,
                field_atom,
                nested_template,
                acc,
                rt
              )

            %{field_name: field_name, index: _index} ->
              extract_resource_field(normalized, resource, field_name, acc, rt)

            _ ->
              acc
          end
        end)
      end
    else
      normalize_primitive(value, rt)
    end
  end

  defp extract_resource_value(value, _resource, _template, rt),
    do: normalize_primitive(value, rt)

  defp extract_resource_field(data, resource, field_atom, acc, rt) do
    case Map.get(data, field_atom) do
      %Ash.ForbiddenField{} ->
        Map.put(acc, field_atom, nil)

      %Ash.NotLoaded{} ->
        acc

      value ->
        field_or_rel = get_field_or_relationship(resource, field_atom, rt)
        extracted = extract_value(value, field_or_rel, [], [], rt)
        Map.put(acc, field_atom, extracted)
    end
  end

  defp extract_resource_nested_field(
         data,
         resource,
         field_atom,
         nested_template,
         acc,
         rt
       ) do
    case Map.get(data, field_atom) do
      %Ash.ForbiddenField{} ->
        Map.put(acc, field_atom, nil)

      %Ash.NotLoaded{} ->
        acc

      nil ->
        Map.put(acc, field_atom, nil)

      value ->
        field_or_rel = get_field_or_relationship(resource, field_atom, rt)
        extracted = extract_value(value, field_or_rel, [], nested_template, rt)
        Map.put(acc, field_atom, extracted)
    end
  end

  # Union Handler — uses type_info.members (hydrated with tag/tag_value and %Ash.Info.Manifest.Type{})
  defp extract_union_value(
         %Ash.Union{type: active_type, value: union_value},
         type_info,
         template,
         rt
       ) do
    members = type_info.members || []
    member_in_template = template == [] or member_in_template?(template, active_type)

    if member_in_template do
      member_template = find_member_template(template, active_type)

      case Enum.find(members, fn m -> m.name == active_type end) do
        nil ->
          %{active_type => normalize_primitive(union_value, rt)}

        member ->
          extracted =
            extract_value(union_value, member.type, [], member_template, rt)

          %{active_type => extracted}
      end
    else
      nil
    end
  end

  defp extract_union_value(value, _type_info, _template, rt),
    do: normalize_primitive(value, rt)

  defp member_in_template?(template, member_name) do
    Enum.any?(template, fn
      {member, _nested} -> member == member_name
      member when is_atom(member) -> member == member_name
      _ -> false
    end)
  end

  defp find_member_template(template, active_type) do
    Enum.find_value(template, [], fn
      {member, nested} when member == active_type -> nested
      member when member == active_type -> []
      _ -> nil
    end)
  end

  # Array Handler
  defp extract_array_value(value, inner_type, template, rt)
       when is_list(value) do
    value
    |> Enum.map(fn item ->
      case extract_value(item, inner_type, [], template, rt) do
        :skip -> nil
        result -> result
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_array_value(value, _inner_type, _template, _rt), do: value

  # TypedStruct Handler — struct types with field constraints
  defp extract_typed_struct_value(value, type_info, template, rt)
       when is_list(value) do
    map_value = Enum.into(value, %{})
    extract_typed_struct_value(map_value, type_info, template, rt)
  end

  defp extract_typed_struct_value(value, type_info, template, rt)
       when is_map(value) do
    normalized = FieldExtractor.normalize_for_extraction(value, template)

    Enum.reduce(template, %{}, fn field_spec, acc ->
      case field_spec do
        field_atom when is_atom(field_atom) ->
          field_value = Map.get(normalized, field_atom)
          sub_type = Type.find_field_type(type_info, field_atom)
          extracted = extract_value(field_value, sub_type, [], [], rt)
          Map.put(acc, field_atom, extracted)

        {field_atom, nested_template} when is_atom(field_atom) ->
          field_value = Map.get(normalized, field_atom)
          sub_type = Type.find_field_type(type_info, field_atom)

          extracted =
            extract_value(field_value, sub_type, [], nested_template, rt)

          Map.put(acc, field_atom, extracted)

        _ ->
          acc
      end
    end)
  end

  defp extract_typed_struct_value(value, _type_info, _template, rt),
    do: normalize_primitive(value, rt)

  # Typed Map Handler
  defp extract_typed_map_value(value, type_info, template, rt)
       when is_list(value) do
    if value != [] and Keyword.keyword?(value) do
      map_value = Map.new(value)
      extract_typed_map_value(map_value, type_info, template, rt)
    else
      normalize_primitive(value, rt)
    end
  end

  defp extract_typed_map_value(value, type_info, template, rt)
       when is_map(value) do
    fields = Type.get_fields(type_info)
    normalized = FieldExtractor.normalize_for_extraction(value, template)

    cond do
      template == [] and fields == [] ->
        normalize_primitive(value, rt)

      template == [] ->
        Enum.reduce(fields, %{}, fn field_desc, acc ->
          field_value = Map.get(normalized, field_desc.name)
          extracted = extract_value(field_value, field_desc.type, [], [], rt)
          Map.put(acc, field_desc.name, extracted)
        end)

      true ->
        Enum.reduce(template, %{}, fn field_spec, acc ->
          case field_spec do
            field_atom when is_atom(field_atom) ->
              field_value = Map.get(normalized, field_atom)
              sub_type = Type.find_field_type(type_info, field_atom)
              extracted = extract_value(field_value, sub_type, [], [], rt)
              Map.put(acc, field_atom, extracted)

            {field_atom, nested_template} when is_atom(field_atom) ->
              field_value = Map.get(normalized, field_atom)
              sub_type = Type.find_field_type(type_info, field_atom)

              extracted =
                extract_value(field_value, sub_type, [], nested_template, rt)

              Map.put(acc, field_atom, extracted)

            %{field_name: field_name, index: _index} ->
              field_value = Map.get(normalized, field_name)
              sub_type = Type.find_field_type(type_info, field_name)
              extracted = extract_value(field_value, sub_type, [], [], rt)
              Map.put(acc, field_name, extracted)

            _ ->
              acc
          end
        end)
    end
  end

  defp extract_typed_map_value(value, type_info, template, rt)
       when is_tuple(value) do
    normalized = FieldExtractor.normalize_for_extraction(value, template)
    extract_typed_map_value(normalized, type_info, template, rt)
  end

  defp extract_typed_map_value(value, _type_info, _template, rt),
    do: normalize_primitive(value, rt)

  defp extract_plain_map_value(value, template, rt) when is_map(value) do
    Enum.reduce(template, %{}, fn field_spec, acc ->
      case field_spec do
        field_atom when is_atom(field_atom) ->
          field_value = plain_map_field(value, field_atom)
          Map.put(acc, field_atom, normalize_primitive(field_value, rt))

        {field_atom, nested_template} when is_atom(field_atom) ->
          field_value = plain_map_field(value, field_atom)

          nested_extracted =
            if is_map(field_value) and nested_template != [] do
              extract_plain_map_value(field_value, nested_template, rt)
            else
              normalize_primitive(field_value, rt)
            end

          Map.put(acc, field_atom, nested_extracted)

        _ ->
          acc
      end
    end)
  end

  defp plain_map_field(map, field_atom) do
    case Map.fetch(map, field_atom) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(field_atom))
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Primitive Normalization
  # ─────────────────────────────────────────────────────────────────────────────

  @doc """
  Normalizes a value without a type template into a JSON-encodable shape:
  keyword lists become maps, `Duration`s become ISO 8601 strings, structs are
  reduced to their public fields, and forbidden fields are redacted.
  """
  @spec normalize_value_for_json(term(), AshRpc.Runtime.t()) :: term()
  def normalize_value_for_json(value, rt), do: normalize_primitive(value, rt)

  def normalize_primitive(nil, _rt), do: nil

  # Authorization-redacted and unloaded fields must never be serialized: the
  # generic struct fallback below would Map.from_struct/1 them and leak
  # Ash.ForbiddenField.original_value (the real value, hidden only from Inspect).
  def normalize_primitive(%Ash.ForbiddenField{}, _rt), do: nil
  def normalize_primitive(%Ash.NotLoaded{}, _rt), do: nil

  def normalize_primitive(value, rt) do
    cond do
      match?(%DateTime{}, value) ->
        DateTime.to_iso8601(value)

      match?(%Date{}, value) ->
        Date.to_iso8601(value)

      match?(%Time{}, value) ->
        Time.to_iso8601(value)

      match?(%NaiveDateTime{}, value) ->
        NaiveDateTime.to_iso8601(value)

      match?(%Duration{}, value) ->
        Duration.to_iso8601(value)

      match?(%Decimal{}, value) ->
        Decimal.to_string(value)

      match?(%Ash.CiString{}, value) ->
        to_string(value)

      match?(%Ash.Union{}, value) ->
        %Ash.Union{type: type_name, value: union_value} = value
        type_key = to_string(type_name)
        %{type_key => normalize_primitive(union_value, rt)}

      is_atom(value) and not is_boolean(value) ->
        Atom.to_string(value)

      is_struct(value) && Introspection.ash_resource?(value.__struct__) ->
        # Resource structs: filter to public fields only
        normalize_resource_struct_primitive(value, rt)

      is_struct(value) ->
        value
        |> Map.from_struct()
        |> Enum.reduce(%{}, fn {key, val}, acc ->
          Map.put(acc, key, normalize_primitive(val, rt))
        end)

      is_list(value) ->
        if value != [] and Keyword.keyword?(value) do
          Enum.reduce(value, %{}, fn {key, val}, acc ->
            string_key = to_string(key)
            Map.put(acc, string_key, normalize_primitive(val, rt))
          end)
        else
          Enum.map(value, &normalize_primitive(&1, rt))
        end

      is_map(value) ->
        Enum.reduce(value, %{}, fn {key, val}, acc ->
          Map.put(acc, key, normalize_primitive(val, rt))
        end)

      true ->
        value
    end
  end

  defp normalize_resource_struct(value, resource, rt) do
    case Map.get(rt.resource_lookup, resource) do
      %Ash.Info.Manifest.Resource{fields: fields} when is_map(fields) ->
        public_field_names = MapSet.new(Map.keys(fields))

        value
        |> Map.from_struct()
        |> Enum.reduce(%{}, fn {key, val}, acc ->
          if MapSet.member?(public_field_names, key) do
            Map.put(acc, key, normalize_primitive(val, rt))
          else
            acc
          end
        end)

      _ ->
        normalize_primitive(value, rt)
    end
  end

  # Normalize a resource struct by filtering to public fields.
  defp normalize_resource_struct_primitive(value, rt) when is_struct(value) do
    resource = value.__struct__

    case Map.get(rt.resource_lookup, resource) do
      %Ash.Info.Manifest.Resource{fields: fields} when is_map(fields) ->
        public_field_names = MapSet.new(Map.keys(fields))

        value
        |> Map.from_struct()
        |> Enum.reduce(%{}, fn {key, val}, acc ->
          if MapSet.member?(public_field_names, key) do
            Map.put(acc, key, normalize_primitive(val, rt))
          else
            acc
          end
        end)

      _ ->
        # Resource not in spec — normalize all fields as a plain struct
        value
        |> Map.from_struct()
        |> Enum.reduce(%{}, fn {key, val}, acc ->
          Map.put(acc, key, normalize_primitive(val, rt))
        end)
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Helper Functions
  # ─────────────────────────────────────────────────────────────────────────────

  defp is_primitive_value?(value) do
    case value do
      %DateTime{} -> true
      %Date{} -> true
      %Time{} -> true
      %NaiveDateTime{} -> true
      %Decimal{} -> true
      %Ash.CiString{} -> true
      _ when is_binary(value) -> true
      _ when is_number(value) -> true
      _ when is_boolean(value) -> true
      _ when is_atom(value) and not is_nil(value) -> true
      _ -> false
    end
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # Entry Points (using type-driven dispatch)
  # ─────────────────────────────────────────────────────────────────────────────

  defp extract_list_fields(results, extraction_template, resource, rt) do
    type = determine_data_type(List.first(results), resource, rt)

    Enum.map(results, fn item ->
      case extract_value(item, type, [], extraction_template, rt) do
        :skip -> nil
        result -> result
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_single_result(data, extraction_template, resource, rt)

  defp extract_single_result(data, extraction_template, resource, rt)
       when is_list(extraction_template) do
    if extraction_template == [] and is_primitive_value?(data) do
      normalize_primitive(data, rt)
    else
      type = determine_data_type(data, resource, rt)
      extract_value(data, type, [], extraction_template, rt)
    end
  end

  defp extract_single_result(data, _template, _resource, _rt) do
    case data do
      %_struct{} = struct_data -> Map.from_struct(struct_data)
      other -> other
    end
  end

  @doc """
  Determines the `%Ash.Info.Manifest.Type{}` for a given data value.
  Returns nil for unknown/primitive types.
  """
  def determine_data_type(nil, resource, rt) do
    resolve_resource_type(resource, rt)
  end

  def determine_data_type(data, resource, rt) do
    cond do
      is_struct(data) && Introspection.ash_resource?(data.__struct__) ->
        resolve_resource_type(data.__struct__, rt)

      is_struct(data) && has_field_name_overrides?(rt, data.__struct__) ->
        Ash.Info.Manifest.Generator.TypeResolver.resolve(Ash.Type.Struct,
          instance_of: data.__struct__
        )

      match?(%Ash.Union{}, data) ->
        resolve_union_type(resource, rt)

      is_list(data) && data != [] && Keyword.keyword?(data) ->
        %Ash.Info.Manifest.Type{kind: :keyword, module: Ash.Type.Keyword, constraints: []}

      is_tuple(data) ->
        %Ash.Info.Manifest.Type{kind: :tuple, module: Ash.Type.Tuple, constraints: []}

      is_map(data) && not is_struct(data) ->
        nil

      resource && Introspection.ash_resource?(resource) && is_struct(data) ->
        resolve_resource_type(resource, rt)

      true ->
        nil
    end
  end

  defp resolve_resource_type(nil, _rt), do: nil

  defp resolve_resource_type(resource, _rt) when is_atom(resource) do
    if Introspection.ash_resource?(resource) do
      %Ash.Info.Manifest.Type{
        kind: :resource,
        name: "Resource",
        module: resource,
        resource_module: resource,
        constraints: []
      }
    else
      nil
    end
  end

  defp resolve_union_type(resource, rt)
       when is_atom(resource) and is_map(rt) do
    case Map.get(rt.resource_lookup, resource) do
      %Ash.Info.Manifest.Resource{fields: fields} when is_map(fields) ->
        # Find the first union field's type from the spec
        union_field =
          Enum.find_value(fields, fn {_name, field} ->
            case field.type do
              %Ash.Info.Manifest.Type{kind: :union} = t ->
                t

              %Ash.Info.Manifest.Type{kind: :type_ref} = t ->
                resolved = Ash.Info.Manifest.get_type!(rt.type_lookup, t.module)
                if resolved.kind == :union, do: resolved, else: nil

              _ ->
                nil
            end
          end)

        union_field ||
          %Ash.Info.Manifest.Type{kind: :union, module: Ash.Type.Union, constraints: []}

      _ ->
        %Ash.Info.Manifest.Type{kind: :union, module: Ash.Type.Union, constraints: []}
    end
  end

  defp resolve_union_type(_resource, _rt) do
    %Ash.Info.Manifest.Type{kind: :union, module: Ash.Type.Union, constraints: []}
  end

  defp has_field_name_overrides?(_rt, nil), do: false

  defp has_field_name_overrides?(rt, module),
    do: not is_nil(Introspection.type_field_name_overrides(rt, module))
end
