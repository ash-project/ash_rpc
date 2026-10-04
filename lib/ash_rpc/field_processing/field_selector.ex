# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldProcessing.FieldSelector do
  @moduledoc """
  Unified field selection processor using type-driven recursive dispatch.

  This module mirrors the architecture of `ValueFormatter` and
  `ResultProcessor`: all three dispatch on `AshRpc.Introspection.classify_type/2`.

  ## Design Principle

  The key insight is that field selection and value formatting are parallel
  operations - both traverse composite types recursively based on type information.
  By using the same dispatch pattern, we achieve consistency and simplicity.

  ## Type Categories

  Dispatch is driven by the manifest: the private `select_fields/4` classifies
  an `%Ash.Info.Manifest.Type{}` and branches on the category. Every handler
  takes a trailing `ctx` argument (a map carrying the `AshRpc.Runtime` plus
  entrypoint-level feature flags).

  | Category | Detection (`type_info.kind`) | Handler |
  |----------|------------------------------|---------|
  | Ash / embedded resource | `:resource`, `:embedded_resource` | `select_resource_fields/4` |
  | Typed struct | struct/map with field-name overrides | `select_typed_struct_fields/4` |
  | Typed Map/Keyword | `:map`/`:keyword` with fields | `select_typed_map_fields/5` |
  | Tuple | `:tuple` | `select_tuple_fields/4` |
  | Union | `:union` | `select_union_fields/5` |
  | Array | `:array` | Recurse with `item_type` |
  | Named type reference | `:type_ref` | Resolve via the runtime's type lookup, re-dispatch |
  | Primitive | Default | Validate no fields requested |
  """

  alias Ash.Info.Manifest.Type
  alias AshRpc.{FieldFormatter, Introspection, LoadRestrictions}
  alias AshRpc.FieldProcessing.Atomizer
  alias AshRpc.FieldProcessing.FieldSelector.Validation
  alias AshRpc.Manifest.Custom

  @type select_result :: {select :: [atom()], load :: [term()], template :: [term()]}

  @default_ctx_flags %{
    enable_filter?: true,
    enable_sort?: true,
    load_restrictions: :none
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Processes requested fields for a given resource and action.

  Returns `{:ok, {select_fields, load_fields, extraction_template}}` or `{:error, error}`.

  ## Parameters

  - `runtime` - The `AshRpc.Runtime`
  - `resource` - The Ash resource module
  - `action_name` - The action name (atom)
  - `requested_fields` - List of field selections (atoms, strings, or maps)

  ## Examples

      iex> process(runtime, MyApp.Todo, :read, [:id, :title, %{user: [:id, :name]}])
      {:ok, {[:id, :title], [{:user, [:id, :name]}], [:id, :title, {:user, [:id, :name]}]}}
  """
  @spec process(AshRpc.Runtime.t(), module(), atom(), list(), keyword()) ::
          {:ok, select_result()} | {:error, term()}
  def process(runtime, resource, action_name, requested_fields, opts \\ []) do
    ctx =
      @default_ctx_flags
      |> Map.merge(Map.new(Keyword.take(opts, Map.keys(@default_ctx_flags))))
      |> Map.put(:runtime, runtime)

    action = Map.get(ctx.runtime.action_lookup, {resource, action_name})

    if is_nil(action) do
      throw({:action_not_found, action_name})
    end

    {select, load, template} =
      resource |> action_return_type(action) |> select_fields(requested_fields, [], ctx)

    formatted_template = format_extraction_template(template)

    {:ok, {select, load, formatted_template}}
  catch
    error_tuple -> {:error, error_tuple}
  end

  # The type a field selection for `action` is applied to.
  defp action_return_type(resource, action) do
    resource_type = resource_type(resource)

    case action do
      %{type: :read, get?: get?} when get? in [false, nil] ->
        %Type{kind: :array, item_type: resource_type, constraints: []}

      %{type: :action, returns: nil} ->
        %Type{kind: :any, module: nil, constraints: []}

      %{type: :action, returns: %Type{} = type} ->
        type

      _ ->
        resource_type
    end
  end

  defp resource_type(resource),
    do: %Type{
      kind: :resource,
      name: "Resource",
      module: resource,
      resource_module: resource,
      constraints: []
    }

  # ---------------------------------------------------------------------------
  # Core Type-Driven Dispatch
  # ---------------------------------------------------------------------------

  # Main recursive dispatch for field selection, mirroring `ValueFormatter.format/5`.
  # Each type category has its own handler that may recurse back into this function.
  @spec select_fields(Type.t() | nil, list(), list(), map()) :: select_result()
  defp select_fields(%Type{} = type_info, requested_fields, path, ctx) do
    case Introspection.classify_type(type_info, ctx.runtime) do
      {:array, item_type} ->
        select_fields(item_type, requested_fields, path, ctx)

      {:resource, resource} ->
        select_resource_fields(resource, requested_fields, path, ctx)

      {:union, type} ->
        select_union_fields(type, requested_fields, path, "union_attribute", ctx)

      {:typed_struct, type} ->
        select_typed_struct_fields(type, requested_fields, path, ctx)

      {:fields, %Type{kind: :tuple} = type} ->
        select_tuple_fields(type, requested_fields, path, ctx)

      {:fields, %Type{kind: kind} = type} ->
        if Type.has_fields?(type) do
          error_type = if kind == :map, do: "map", else: "field_constrained_type"
          select_typed_map_fields(type, requested_fields, path, ctx, error_type)
        else
          select_primitive(type, requested_fields, path)
        end

      {:other, %Type{kind: :any}} ->
        select_generic_fields(requested_fields, ctx)

      {:other, type} ->
        select_primitive(type, requested_fields, path)
    end
  end

  # Catch-all for a missing type
  defp select_fields(_type, requested_fields, path, _ctx),
    do: select_primitive(nil, requested_fields, path)

  # Primitives have no sub-fields: any requested selection is an error.
  defp select_primitive(_type_info, [], _path), do: {[], [], []}

  defp select_primitive(type_info, requested_fields, path),
    do: throw({:invalid_field_selection, :primitive_type, type_info, requested_fields, path})

  # ---------------------------------------------------------------------------
  # Resource Field Selection
  # ---------------------------------------------------------------------------

  # Selects fields from an Ash resource.
  #
  # Handles attributes, calculations, relationships, and aggregates.
  defp select_resource_fields(resource, requested_fields, path, ctx) do
    Validation.check_for_duplicates(requested_fields, path, ctx.runtime.input_formatter)

    Enum.reduce(requested_fields, {[], [], []}, fn field, acc ->
      # Only names on `resource` are translated here; nested values are
      # translated when selection recurses into each field's destination type.
      field
      |> Atomizer.atomize_field(resource, ctx.runtime)
      |> parse_field_request()
      |> process_resource_request(resource, path, acc, ctx)
    end)
  end

  defp process_resource_request({:simple, field_name}, resource, path, acc, ctx),
    do: process_simple_resource_field(resource, field_name, path, acc, ctx)

  defp process_resource_request({:nested, field_name, nested}, resource, path, acc, ctx),
    do: process_nested_resource_field(resource, field_name, nested, path, acc, ctx)

  defp process_resource_request(
         {:with_query_opts, field_name, opts, fields},
         resource,
         path,
         acc,
         ctx
       ),
       do:
         process_relationship_with_query_opts(resource, field_name, opts, fields, path, acc, ctx)

  defp process_resource_request({:with_args, calc_name, args, fields}, resource, path, acc, ctx),
    do: process_args_or_relationship_envelope(resource, calc_name, args, fields, path, acc, ctx)

  defp process_resource_request({:multi_nested, entries}, resource, path, acc, ctx) do
    Enum.reduce(entries, acc, fn {field_name, nested}, inner_acc ->
      field_name
      |> parse_nested(nested)
      |> process_resource_request(resource, path, inner_acc, ctx)
    end)
  end

  defp process_simple_resource_field(
         resource,
         field_name,
         path,
         {select, load, template},
         ctx
       ) do
    internal_name = resolve_resource_field_name(resource, field_name, ctx)

    {field_type, category} =
      get_resource_field_info(resource, internal_name, path, ctx)

    if category == :calculation_with_args do
      throw({:calculation_requires_args, internal_name, path})
    end

    if requires_nested_selection?(field_type, ctx) do
      throw({:requires_field_selection, category, internal_name, path})
    end

    case category do
      :attribute ->
        {select ++ [internal_name], load, template ++ [internal_name]}

      :relationship ->
        throw({:requires_field_selection, :relationship, internal_name, path})

      cat when cat in [:calculation, :aggregate] ->
        check_load_allowed!(path, internal_name, ctx)
        {select, load ++ [internal_name], template ++ [internal_name]}
    end
  end

  defp process_nested_resource_field(
         resource,
         field_name,
         nested_fields,
         path,
         {select, load, template},
         ctx
       ) do
    internal_name = resolve_resource_field_name(resource, field_name, ctx)

    {field_type, category} =
      get_resource_field_info(resource, internal_name, path, ctx)

    if category == :calculation_with_args do
      throw({:invalid_calculation_args, internal_name, path})
    end

    # Aggregates that don't return complex types don't support nested field selection
    if category == :aggregate &&
         !requires_nested_selection?(field_type, ctx) do
      throw({:invalid_field_selection, internal_name, :aggregate, path})
    end

    if category == :calculation && is_map(nested_fields) do
      throw({:invalid_calculation_args, internal_name, path})
    end

    if category == :calculation &&
         !requires_nested_selection?(field_type, ctx) do
      throw({:field_does_not_support_nesting, internal_name, path})
    end

    if category == :attribute &&
         !requires_nested_selection?(field_type, ctx) do
      throw({:field_does_not_support_nesting, internal_name, path})
    end

    # For union types (attributes or aggregates), nested_fields can be a map (member selection)
    is_union_type = match?(%Ash.Info.Manifest.Type{kind: :union}, field_type)

    if category == :union_attribute || is_union_type do
      if is_list(nested_fields) && nested_fields == [] do
        throw({:requires_field_selection, :union, internal_name, path})
      end
    else
      Validation.validate_non_empty(nested_fields, internal_name, path, category)
    end

    new_path = path ++ [internal_name]

    {nested_select, nested_load, nested_template} =
      select_fields(field_type, nested_fields, new_path, ctx)

    case category do
      cat
      when cat in [
             :attribute,
             :embedded_resource,
             :tuple,
             :field_constrained_type,
             :union_attribute
           ] ->
        new_load =
          if nested_load != [] do
            check_load_allowed!(path, internal_name, ctx)
            load ++ [{internal_name, nested_load}]
          else
            load
          end

        {select ++ [internal_name], new_load, template ++ [{internal_name, nested_template}]}

      :relationship ->
        dest_resource = extract_relationship_destination(field_type, resource, internal_name)

        unless Custom.exposed?(Map.get(ctx.runtime.resource_lookup, dest_resource)) do
          throw({:unknown_field, internal_name, resource, path})
        end

        check_load_allowed!(path, internal_name, ctx)
        load_spec = {internal_name, nested_select ++ nested_load}
        {select, load ++ [load_spec], template ++ [{internal_name, nested_template}]}

      :calculation ->
        check_load_allowed!(path, internal_name, ctx)
        load_spec = {internal_name, nested_select ++ nested_load}
        {select, load ++ [load_spec], template ++ [{internal_name, nested_template}]}

      :calculation_complex ->
        # Calculations returning complex types need different load formats depending
        # on whether the return type is a resource (which supports load_through via
        # Ash queries) or a non-resource type (TypedStruct/map where sub-field
        # extraction is handled by the template).
        returns_resource = calculation_returns_resource?(field_type)
        check_load_allowed!(path, internal_name, ctx)

        load_spec =
          if returns_resource do
            # Resource-returning calculations use load_through format:
            # {calc_name, {args_map, load_through_fields}}
            {internal_name, {%{}, nested_select ++ nested_load}}
          else
            # Non-resource types (TypedStruct/map): load the calculation itself,
            # template handles sub-field extraction
            internal_name
          end

        {select, load ++ [load_spec], template ++ [{internal_name, nested_template}]}

      :aggregate ->
        # Aggregates don't support nested loads - just load the aggregate itself
        # The template will handle extracting nested fields from the result
        check_load_allowed!(path, internal_name, ctx)
        {select, load ++ [internal_name], template ++ [{internal_name, nested_template}]}

      :calculation_with_args ->
        throw({:invalid_calculation_args, internal_name, path})
    end
  end

  defp process_calculation_with_args(
         resource,
         calc_name,
         args,
         fields,
         path,
         {select, load, template},
         ctx
       ) do
    internal_name = resolve_resource_field_name(resource, calc_name, ctx)

    calc_field =
      case Ash.Info.Manifest.get_field(
             ctx.runtime.resource_lookup,
             resource,
             internal_name
           ) do
        %Ash.Info.Manifest.Field{kind: :calculation} = f -> f
        _ -> nil
      end

    if is_nil(calc_field) do
      throw({:unknown_field, internal_name, resource, path})
    end

    field_type = calc_field.type
    new_path = path ++ [internal_name]
    is_complex_return_type = requires_nested_selection?(field_type, ctx)

    calc_accepts_args = has_any_arguments?(calc_field)
    calc_requires_args = has_required_arguments?(calc_field)
    has_non_empty_args = args != nil && args != %{}

    cond do
      calc_accepts_args && args == nil ->
        throw({:invalid_calculation_args, internal_name, path})

      has_non_empty_args && !calc_accepts_args ->
        throw({:invalid_calculation_args, internal_name, path})

      !calc_accepts_args && !is_complex_return_type && args != nil ->
        throw({:invalid_calculation_args, internal_name, path})

      calc_requires_args && !has_non_empty_args ->
        throw({:invalid_calculation_args, internal_name, path})

      true ->
        :ok
    end

    {nested_select, nested_load, nested_template} =
      cond do
        not is_nil(fields) and not is_complex_return_type ->
          throw({:invalid_field_selection, internal_name, :calculation, path})

        is_list(fields) and fields != [] ->
          select_fields(field_type, fields, new_path, ctx)

        is_complex_return_type ->
          throw({:requires_field_selection, :complex_type, internal_name, path})

        true ->
          {[], [], []}
      end

    load_fields = nested_select ++ nested_load

    load_spec =
      cond do
        args != nil && load_fields != [] ->
          {internal_name, {args, load_fields}}

        args != nil ->
          {internal_name, args}

        load_fields != [] ->
          {internal_name, load_fields}

        true ->
          internal_name
      end

    template_item =
      if nested_template == [] do
        internal_name
      else
        {internal_name, nested_template}
      end

    check_load_allowed!(path, internal_name, ctx)

    {select, load ++ [load_spec], template ++ [template_item]}
  end

  # ---------------------------------------------------------------------------
  # Relationship Query Envelopes
  # ---------------------------------------------------------------------------

  # An args/fields map targeted at a relationship is a bare-fields envelope
  # (e.g. %{comments: %{fields: [...]}}) — route it through the query-opts
  # processor. Calculations keep the existing args path.
  defp process_args_or_relationship_envelope(resource, calc_name, args, fields, path, acc, ctx) do
    internal = resolve_resource_field_name(resource, calc_name, ctx)

    case get_resource_relationship(resource, internal, ctx.runtime) do
      %Ash.Info.Manifest.Relationship{} ->
        process_relationship_with_query_opts(
          resource,
          calc_name,
          %{args: args},
          fields,
          path,
          acc,
          ctx
        )

      nil ->
        process_calculation_with_args(resource, calc_name, args, fields, path, acc, ctx)
    end
  end

  # Fields take precedence over relationships, mirroring
  # get_resource_field_info_from_spec.
  defp get_resource_relationship(resource, field_name, runtime) do
    api_resource =
      Ash.Info.Manifest.get_resource!(runtime.resource_lookup, resource)

    if Map.has_key?(api_resource.fields, field_name) do
      nil
    else
      Map.get(api_resource.relationships, field_name)
    end
  end

  defp process_relationship_with_query_opts(
         resource,
         field_name,
         opts,
         fields,
         path,
         {select, load, template},
         ctx
       ) do
    internal_name = resolve_resource_field_name(resource, field_name, ctx)

    rel = get_resource_relationship(resource, internal_name, ctx.runtime)
    rel = validate_query_opts!(resource, internal_name, rel, opts, fields, path, ctx)

    %Ash.Info.Manifest.Relationship{destination: dest} = rel

    new_path = path ++ [internal_name]

    dest_type = resource_type(dest)

    {nested_select, nested_load, nested_template} =
      select_fields(dest_type, fields, new_path, ctx)

    input_formatter = ctx.runtime.input_formatter

    parsed_page =
      case Map.get(opts, :page) do
        nil ->
          nil

        page ->
          parse_nested_page(
            page,
            internal_name,
            path,
            input_formatter,
            Custom.relationship_pagination(rel)
          )
      end

    parsed_filter =
      case Map.get(opts, :filter) do
        nil -> nil
        filter -> FieldFormatter.parse_input_fields(filter, input_formatter)
      end

    parsed_sort =
      case Map.get(opts, :sort) do
        nil -> nil
        sort -> FieldFormatter.format_sort_string(sort, input_formatter)
      end

    query =
      dest
      |> Ash.Query.for_read(Custom.relationship_read_action(rel))
      |> then(fn q ->
        if parsed_filter, do: Ash.Query.filter_input(q, parsed_filter), else: q
      end)
      |> then(fn q -> if parsed_sort, do: Ash.Query.sort_input(q, parsed_sort), else: q end)
      |> then(fn q ->
        if parsed_page, do: Ash.Query.page(q, Keyword.new(parsed_page)), else: q
      end)
      |> then(fn q ->
        case Map.get(opts, :limit) do
          nil -> q
          limit -> Ash.Query.limit(q, limit)
        end
      end)
      |> then(fn q ->
        case Map.get(opts, :offset) do
          nil -> q
          offset -> Ash.Query.offset(q, offset)
        end
      end)
      |> Ash.Query.select(nested_select)
      |> Ash.Query.load(nested_load)

    check_load_allowed!(path, internal_name, ctx)

    {select, load ++ [{internal_name, query}], template ++ [{internal_name, nested_template}]}
  end

  @offset_page_keys [:limit, :offset, :count]
  @keyset_page_keys [:limit, :after, :before, :count]

  # Validation order (spec):
  # 1. relationship  2. cardinality :many  3. destination is RPC resource
  # 4. args exclusivity  5. page vs pagination capability  6. filter gates
  # 7. sort gates  8. page xor bare limit/offset  9. non-empty fields
  defp validate_query_opts!(resource, internal_name, rel, opts, fields, path, ctx) do
    rel =
      case rel do
        nil ->
          case get_resource_field_kind(resource, internal_name, ctx.runtime) do
            nil -> throw({:unknown_field, internal_name, resource, path})
            kind -> throw({:query_opts_on_non_relationship, internal_name, kind, path})
          end

        %Ash.Info.Manifest.Relationship{cardinality: :one} ->
          throw({:query_opts_on_to_one, internal_name, path})

        %Ash.Info.Manifest.Relationship{cardinality: :many} = rel ->
          rel
      end

    unless Custom.exposed?(Map.get(ctx.runtime.resource_lookup, rel.destination)) do
      throw({:unknown_field, internal_name, resource, path})
    end

    if Map.get(opts, :args) != nil do
      throw({:args_and_query_opts_combined, internal_name, path})
    end

    if Map.get(opts, :page) != nil and Custom.relationship_pagination(rel) == :none do
      throw({:nested_pagination_not_supported, internal_name, path})
    end

    if Map.get(opts, :filter) != nil do
      cond do
        not ctx.enable_filter? ->
          throw({:filter_not_supported, internal_name, :disabled, path})

        not rel.filterable? ->
          throw({:filter_not_supported, internal_name, :unsupported, path})

        true ->
          :ok
      end
    end

    if Map.get(opts, :sort) != nil do
      cond do
        not ctx.enable_sort? ->
          throw({:sort_not_supported, internal_name, :disabled, path})

        not rel.sortable? ->
          throw({:sort_not_supported, internal_name, :unsupported, path})

        true ->
          :ok
      end
    end

    if Map.get(opts, :page) != nil and
         (Map.get(opts, :limit) != nil or Map.get(opts, :offset) != nil) do
      throw({:page_and_limit_offset_combined, internal_name, path})
    end

    if is_nil(fields) or fields == [] do
      throw({:requires_field_selection, :relationship, internal_name, path})
    end

    rel
  end

  defp get_resource_field_kind(resource, field_name, runtime) do
    api_resource =
      Ash.Info.Manifest.get_resource!(runtime.resource_lookup, resource)

    case Map.get(api_resource.fields, field_name) do
      %Ash.Info.Manifest.Field{kind: kind} -> kind
      nil -> nil
    end
  end

  defp parse_nested_page(page, field_name, path, formatter, pagination) when is_map(page) do
    parsed = FieldFormatter.parse_input_fields(page, formatter)

    allowed =
      case pagination do
        :offset -> @offset_page_keys
        :keyset -> @keyset_page_keys
        _ -> Enum.uniq(@offset_page_keys ++ @keyset_page_keys)
      end

    invalid = Map.keys(parsed) -- allowed

    if invalid != [] do
      throw({:invalid_nested_page, field_name, {:unknown_keys, invalid}, path})
    end

    parsed
  end

  defp parse_nested_page(_page, field_name, path, _formatter, _pagination) do
    throw({:invalid_nested_page, field_name, :not_a_map, path})
  end

  defp get_resource_field_info(resource, field_name, path, ctx)
       when is_atom(resource) do
    api_resource =
      Ash.Info.Manifest.get_resource!(ctx.runtime.resource_lookup, resource)

    get_resource_field_info_from_spec(api_resource, resource, field_name, path, ctx)
  end

  defp get_resource_field_info_from_spec(api_resource, resource, field_name, path, ctx) do
    case Map.get(api_resource.fields, field_name) do
      %Ash.Info.Manifest.Field{kind: kind, type: type_info} = field ->
        case kind do
          :calculation ->
            category =
              cond do
                has_any_arguments?(field) ->
                  :calculation_with_args

                requires_nested_selection?(type_info, ctx) ->
                  :calculation_complex

                true ->
                  :calculation
              end

            {type_info, category}

          :attribute ->
            # Use the type info to classify - use the fallback classifier
            # since it handles all the nested selection logic correctly
            category = classify_attribute_category_from_type(type_info, ctx)
            {type_info, category}

          :aggregate ->
            {type_info, :aggregate}
        end

      nil ->
        case Map.get(api_resource.relationships, field_name) do
          %Ash.Info.Manifest.Relationship{destination: dest, cardinality: cardinality} ->
            dest_type = resource_type(dest)

            type =
              if cardinality == :many do
                %Ash.Info.Manifest.Type{
                  kind: :array,
                  name: "Array",
                  item_type: dest_type,
                  constraints: []
                }
              else
                dest_type
              end

            {type, :relationship}

          nil ->
            throw({:unknown_field, field_name, resource, path})
        end
    end
  end

  defp classify_attribute_category_from_type(
         %Ash.Info.Manifest.Type{kind: :type_ref} = type_info,
         ctx
       ) do
    full_type =
      Ash.Info.Manifest.get_type!(ctx.runtime.type_lookup, type_info.module)

    classify_attribute_category_from_type(full_type, ctx)
  end

  defp classify_attribute_category_from_type(%Ash.Info.Manifest.Type{} = type_info, ctx) do
    # For array types, classify based on the inner type
    effective_type = if type_info.kind == :array, do: type_info.item_type, else: type_info

    case effective_type do
      %Ash.Info.Manifest.Type{kind: :type_ref} = ref ->
        full_type =
          Ash.Info.Manifest.get_type!(ctx.runtime.type_lookup, ref.module)

        classify_attribute_category_from_type(full_type, ctx)

      %Ash.Info.Manifest.Type{kind: kind} when kind in [:resource, :embedded_resource] ->
        :embedded_resource

      %Ash.Info.Manifest.Type{kind: :union} ->
        :union_attribute

      %Ash.Info.Manifest.Type{kind: :tuple} ->
        :tuple

      %Ash.Info.Manifest.Type{kind: kind} = t
      when kind in [:struct, :map, :keyword] ->
        if Type.has_fields?(t) do
          :field_constrained_type
        else
          :attribute
        end

      _ ->
        :attribute
    end
  end

  defp has_any_arguments?(calc) do
    case calc.arguments do
      [] -> false
      nil -> false
      args when is_list(args) -> true
    end
  end

  defp has_required_arguments?(calc) do
    case calc.arguments do
      [] ->
        false

      nil ->
        false

      args when is_list(args) ->
        Enum.any?(args, fn arg -> !arg.allow_nil? end)
    end
  end

  # ---------------------------------------------------------------------------
  # TypedStruct Field Selection
  # ---------------------------------------------------------------------------

  # Selects fields from a struct type with field constraints (e.g. a TypedStruct).
  defp select_typed_struct_fields(
         %Ash.Info.Manifest.Type{} = type_info,
         requested_fields,
         path,
         ctx
       ) do
    if requested_fields == [] do
      throw({:requires_field_selection, :field_constrained_type, path})
    end

    {_forward, reverse_map} = typed_struct_field_maps(type_info, ctx)

    typed = %{
      type_info: type_info,
      fields: Type.get_fields(type_info),
      error_type: "field_constrained_type",
      resolve: &resolve_typed_struct_field(&1, reverse_map, ctx)
    }

    select_typed_entries(requested_fields, typed, path, ctx)
  end

  # Shared by typed structs and typed maps; `typed.resolve` maps a requested
  # name to the internal field name, which must exist in `typed.fields`.
  defp select_typed_entries(requested_fields, typed, path, ctx) do
    Validation.check_for_duplicates(requested_fields, path, ctx.runtime.input_formatter)

    Enum.reduce(requested_fields, {[], [], []}, fn field, acc ->
      select_typed_entry(parse_field_request(field), field, typed, path, acc, ctx)
    end)
  end

  defp select_typed_entry(request, field, typed, path, {select, load, template} = acc, ctx) do
    case request do
      {:simple, field_name} ->
        {select, load, template ++ [typed_field!(typed, field_name, path)]}

      {:nested, field_name, nested} ->
        internal_name = typed_field!(typed, field_name, path)
        sub_type = Type.find_field_type(typed.type_info, internal_name)

        {_nested_select, _nested_load, nested_template} =
          select_fields(sub_type, nested, path ++ [internal_name], ctx)

        {select, load, template ++ [{internal_name, nested_template}]}

      {:multi_nested, entries} ->
        Enum.reduce(entries, acc, fn {field_name, nested}, inner_acc ->
          field_name
          |> parse_nested(nested)
          |> select_typed_entry(%{field_name => nested}, typed, path, inner_acc, ctx)
        end)

      {:with_query_opts, field_name, _opts, _fields} ->
        reject_query_opts!(field_name, "typed field", path)

      {:with_args, _calc_name, _args, _fields} ->
        throw({:invalid_field_format, field, path})
    end
  end

  defp typed_field!(typed, field_name, path) do
    internal_name = typed.resolve.(field_name)
    validate_field_exists_in_fields!(internal_name, typed.fields, path, typed.error_type)
    internal_name
  end

  # Query options (page/filter/sort/limit/offset) only apply to to-many
  # relationships; typed struct/map/tuple/union fields never accept them.
  defp reject_query_opts!(field_name, kind, path),
    do: throw({:query_opts_on_non_relationship, field_name, kind, path})

  # Returns `{forward, reverse}` client field-name maps for a typed struct,
  # preferring the decoration on the type in hand and falling back to
  # `AshRpc.Introspection.type_field_name_overrides/2` (type lookup, then the
  # mapping source).
  defp typed_struct_field_maps(type_info, ctx) do
    case Custom.type_field_name_overrides_pair(type_info) do
      nil ->
        forward =
          Introspection.type_field_name_overrides(ctx.runtime, Type.effective_module(type_info)) ||
            %{}

        {forward, Map.new(forward, fn {k, v} -> {v, k} end)}

      pair ->
        pair
    end
  end

  defp resolve_typed_struct_field(field_name, reverse_map, ctx) when is_binary(field_name) do
    case Map.get(reverse_map, field_name) do
      # Never mint an atom here: an unresolved name has no matching field atom, so
      # it stays a string and fails validate_field_exists_in_fields!/4 as an unknown
      # field. Minting would only let client input grow the atom table.
      nil -> resolve_field_name(field_name, ctx)
      internal -> internal
    end
  end

  defp resolve_typed_struct_field(field_name, _reverse_map, _ctx) when is_atom(field_name),
    do: field_name

  # ---------------------------------------------------------------------------
  # Typed Map Field Selection
  # ---------------------------------------------------------------------------

  # Selects fields from a typed map (Ash.Type.Map/Keyword with field constraints).
  #
  # The error_type parameter allows distinguishing between different type categories
  # for better error messages.
  defp select_typed_map_fields(
         %Ash.Info.Manifest.Type{} = type_info,
         requested_fields,
         path,
         ctx,
         error_type
       ) do
    if requested_fields == [] do
      throw({:requires_field_selection, :field_constrained_type, path})
    end

    typed = %{
      type_info: type_info,
      fields: Type.get_fields(type_info),
      error_type: error_type,
      resolve: &resolve_field_name(&1, ctx)
    }

    select_typed_entries(requested_fields, typed, path, ctx)
  end

  # ---------------------------------------------------------------------------
  # Tuple Field Selection
  # ---------------------------------------------------------------------------

  # Selects fields from a tuple type using named fields.
  #
  # Tuples in Ash have named positions (like :latitude, :longitude) and the
  # template stores both the field_name and its index for result processing.
  # When no fields are requested, all fields are returned.
  defp select_tuple_fields(%Ash.Info.Manifest.Type{} = type_info, requested_fields, path, ctx) do
    fields = Type.get_fields(type_info)
    field_names = Enum.map(fields, fn f -> f.name end)

    # If no fields requested, return all fields
    if requested_fields == [] do
      template =
        field_names
        |> Enum.with_index()
        |> Enum.map(fn {name, index} -> %{field_name: name, index: index} end)

      {[], [], template}
    else
      Validation.check_for_duplicates(requested_fields, path, ctx.runtime.input_formatter)

      Enum.reduce(requested_fields, {[], [], []}, fn field, {select, load, template} ->
        case parse_field_request(field) do
          {:simple, field_name} ->
            field_atom = resolve_field_name(field_name, ctx)

            validate_field_exists_in_fields!(field_atom, fields, path, "tuple")

            index = Enum.find_index(field_names, &(&1 == field_atom))
            {select, load, template ++ [%{field_name: field_atom, index: index}]}

          {:nested, field_name, nested_fields} ->
            field_atom = resolve_field_name(field_name, ctx)

            validate_field_exists_in_fields!(field_atom, fields, path, "tuple")

            sub_type = Type.find_field_type(type_info, field_atom)
            new_path = path ++ [field_atom]

            {_nested_select, _nested_load, nested_template} =
              select_fields(sub_type, nested_fields, new_path, ctx)

            {select, load, template ++ [{field_atom, nested_template}]}

          {:multi_nested, entries} ->
            Enum.reduce(entries, {select, load, template}, fn {field_name, nested_fields},
                                                              {s, l, t} ->
              field_atom = resolve_field_name(field_name, ctx)

              validate_field_exists_in_fields!(field_atom, fields, path, "tuple")

              index = Enum.find_index(field_names, &(&1 == field_atom))

              if is_list(nested_fields) do
                sub_type = Type.find_field_type(type_info, field_atom)
                new_path = path ++ [field_atom]

                {_nested_select, _nested_load, nested_template} =
                  select_fields(sub_type, nested_fields, new_path, ctx)

                {s, l, t ++ [{field_atom, nested_template}]}
              else
                {s, l, t ++ [%{field_name: field_atom, index: index}]}
              end
            end)

          {:with_query_opts, field_name, _opts, _fields} ->
            reject_query_opts!(field_name, "tuple field", path)

          {:with_args, _calc_name, _args, _fields} ->
            throw({:invalid_field_format, field, path})
        end
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Union Field Selection
  # ---------------------------------------------------------------------------

  # Selects fields from a union type.
  #
  # Supports:
  # - Simple member selection: [:member_name]
  # - Member with nested fields: [%{member_name: fields}]
  # - Multiple members in a single map: %{member1: fields1, member2: fields2}
  defp select_union_fields(
         %Ash.Info.Manifest.Type{} = type_info,
         requested_fields,
         path,
         error_type,
         ctx
       ) do
    members = type_info.members || []
    normalized_fields = normalize_union_fields(requested_fields)

    Validation.validate_non_empty(normalized_fields, "union", path, :union)
    Validation.check_for_duplicates(normalized_fields, path, ctx.runtime.input_formatter)

    {load_items, template_items} =
      Enum.reduce(normalized_fields, {[], []}, fn field, {load_acc, template_acc} ->
        case parse_field_request(field) do
          {:simple, member_name} ->
            process_simple_union_member_spec(
              member_name,
              members,
              path,
              error_type,
              load_acc,
              template_acc,
              ctx
            )

          {:nested, member_name, nested_fields} ->
            process_nested_union_member_spec(
              member_name,
              nested_fields,
              members,
              path,
              error_type,
              load_acc,
              template_acc,
              ctx
            )

          {:multi_nested, entries} ->
            Enum.reduce(entries, {load_acc, template_acc}, fn {member_name, nested_fields},
                                                              {l_acc, t_acc} ->
              process_nested_union_member_spec(
                member_name,
                nested_fields,
                members,
                path,
                error_type,
                l_acc,
                t_acc,
                ctx
              )
            end)

          {:with_query_opts, member_name, _opts, _fields} ->
            reject_query_opts!(member_name, "union member", path)

          {:with_args, _calc_name, _args, _fields} ->
            throw({:invalid_field_format, field, path})
        end
      end)

    {[], load_items, template_items}
  end

  # Spec-based union member processing (uses %{name, type: %Ash.Info.Manifest.Type{}} members)

  defp process_simple_union_member_spec(
         member_name,
         members,
         path,
         error_type,
         load_acc,
         template_acc,
         ctx
       ) do
    internal_name = resolve_field_name(member_name, ctx)
    member = find_union_member_spec(members, internal_name)

    unless member do
      throw({:unknown_field, internal_name, error_type, path})
    end

    # Check if member requires nested selection (embedded resources, typed maps, etc.)
    if requires_nested_selection?(member.type, ctx) do
      throw({:requires_field_selection, :complex_type, internal_name, path})
    end

    {load_acc, template_acc ++ [internal_name]}
  end

  defp process_nested_union_member_spec(
         member_name,
         nested_fields,
         members,
         path,
         error_type,
         load_acc,
         template_acc,
         ctx
       ) do
    internal_name = resolve_field_name(member_name, ctx)
    member = find_union_member_spec(members, internal_name)

    unless member do
      throw({:unknown_field, internal_name, error_type, path})
    end

    new_path = path ++ [internal_name]

    {_nested_select, nested_load, nested_template} =
      select_fields(member.type, nested_fields, new_path, ctx)

    if nested_load != [] do
      check_load_allowed!(path, internal_name, ctx)

      {load_acc ++ [{internal_name, nested_load}],
       template_acc ++ [{internal_name, nested_template}]}
    else
      {load_acc, template_acc ++ [{internal_name, nested_template}]}
    end
  end

  defp find_union_member_spec(members, name) do
    Enum.find(members, fn m -> m.name == name end)
  end

  defp normalize_union_fields(%{} = map) when map_size(map) > 0, do: [map]
  defp normalize_union_fields(fields) when is_list(fields), do: fields
  defp normalize_union_fields(fields), do: fields

  # ---------------------------------------------------------------------------
  # Generic Field Selection (for :any return type)
  # ---------------------------------------------------------------------------

  defp select_generic_fields(requested_fields, ctx) do
    template =
      Enum.map(requested_fields, fn
        field_name when is_atom(field_name) -> field_name
        field_name when is_binary(field_name) -> resolve_field_name(field_name, ctx)
        %{} = field_map -> Enum.map(field_map, fn {k, v} -> {k, v} end)
      end)

    {[], [], List.flatten(template)}
  end

  # ---------------------------------------------------------------------------
  # Helper Functions
  # ---------------------------------------------------------------------------

  defp parse_field_request(field) do
    case field do
      field_name when is_atom(field_name) or is_binary(field_name) ->
        {:simple, field_name}

      {field_name, nested} ->
        parse_nested(field_name, nested)

      %{} = field_map when map_size(field_map) == 1 ->
        [{field_name, nested}] = Map.to_list(field_map)
        parse_nested(field_name, nested)

      %{} = field_map when map_size(field_map) > 1 ->
        {:multi_nested, Map.to_list(field_map)}

      %{} ->
        {:simple, nil}
    end
  end

  defp parse_nested(field_name, %{} = nested) do
    case classify_nested_map(nested) do
      {:with_query_opts, opts, fields} -> {:with_query_opts, field_name, opts, fields}
      {:with_args, args, fields} -> {:with_args, field_name, args, fields}
      :not_args_structure -> {:nested, field_name, nested}
    end
  end

  defp parse_nested(field_name, nested), do: {:nested, field_name, nested}

  @query_opt_keys [:page, :filter, :sort, :limit, :offset]

  # Collects envelope query options from a nested map (string or atom keys).
  # Returns {:ok, opts_map} when at least one option key is present, else
  # :no_query_opts. Absent keys are simply missing from the map.
  defp get_query_opts(map) when is_map(map) do
    opts =
      Enum.reduce(@query_opt_keys, %{}, fn key, acc ->
        case fetch_string_or_atom(map, key) do
          {:ok, value} -> Map.put(acc, key, value)
          :error -> acc
        end
      end)

    if opts == %{}, do: :no_query_opts, else: {:ok, opts}
  end

  defp fetch_string_or_atom(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp classify_nested_map(nested) do
    case get_query_opts(nested) do
      {:ok, opts} ->
        {args, fields} =
          case get_args_and_fields(nested) do
            {:ok, args, fields} -> {args, fields}
            :not_args_structure -> {nil, nil}
          end

        {:with_query_opts, Map.put(opts, :args, args), fields}

      :no_query_opts ->
        case get_args_and_fields(nested) do
          {:ok, args, fields} -> {:with_args, args, fields}
          :not_args_structure -> :not_args_structure
        end
    end
  end

  # Extracts args and fields from a map, handling both atom and string keys.
  # Returns {:ok, args, fields} or :not_args_structure.
  defp get_args_and_fields(map) when is_map(map) do
    args = Map.get(map, :args) || Map.get(map, "args")
    has_fields_key = Map.has_key?(map, :fields) || Map.has_key?(map, "fields")

    cond do
      args != nil ->
        fields =
          cond do
            Map.has_key?(map, :fields) -> Map.get(map, :fields)
            Map.has_key?(map, "fields") -> Map.get(map, "fields")
            true -> nil
          end

        {:ok, args, fields}

      has_fields_key ->
        fields = Map.get(map, :fields) || Map.get(map, "fields")
        {:ok, nil, fields}

      true ->
        :not_args_structure
    end
  end

  defp resolve_resource_field_name(resource, field_name, ctx)
       when is_binary(field_name) do
    res_struct = Map.get(ctx.runtime.resource_lookup, resource)

    if Custom.exposed?(res_struct) do
      case Custom.original_field_name(res_struct, field_name) do
        original when is_atom(original) and not is_nil(original) -> original
        _ -> resolve_field_name(field_name, ctx)
      end
    else
      resolve_field_name(field_name, ctx)
    end
  end

  defp resolve_resource_field_name(resource, field_name, ctx)
       when is_atom(field_name) do
    Custom.original_field_name(Map.get(ctx.runtime.resource_lookup, resource), field_name) ||
      field_name
  end

  defp resolve_field_name(field_name, ctx) do
    FieldFormatter.resolve_field_name(field_name, ctx.runtime.input_formatter)
  end

  # Extracts relationship destination from Ash.Info.Manifest type info
  defp extract_relationship_destination(
         %Ash.Info.Manifest.Type{resource_module: dest},
         _resource,
         _name
       )
       when not is_nil(dest),
       do: dest

  defp extract_relationship_destination(
         %Ash.Info.Manifest.Type{item_type: %Ash.Info.Manifest.Type{resource_module: dest}},
         _resource,
         _name
       )
       when not is_nil(dest),
       do: dest

  defp extract_relationship_destination(_, _resource, _name), do: nil

  defp requires_nested_selection?(%Ash.Info.Manifest.Type{kind: :type_ref} = type_info, ctx) do
    full_type =
      Ash.Info.Manifest.get_type!(ctx.runtime.type_lookup, type_info.module)

    requires_nested_selection?(full_type, ctx)
  end

  defp requires_nested_selection?(%Ash.Info.Manifest.Type{} = type_info, ctx) do
    effective_type = if type_info.kind == :array, do: type_info.item_type, else: type_info

    case effective_type do
      %Ash.Info.Manifest.Type{kind: :type_ref} = ref ->
        full_type =
          Ash.Info.Manifest.get_type!(ctx.runtime.type_lookup, ref.module)

        requires_nested_selection?(full_type, ctx)

      %Ash.Info.Manifest.Type{kind: kind} when kind in [:resource, :embedded_resource] ->
        true

      %Ash.Info.Manifest.Type{kind: :union} ->
        true

      %Ash.Info.Manifest.Type{kind: kind} = t when kind in [:tuple, :keyword, :struct, :map] ->
        Type.has_fields?(t)

      _ ->
        false
    end
  end

  # Called at every point where this module appends to the Ash load statement:
  # a load can only reach the load statement through one of these calls, so the
  # action's allowed_loads/denied_loads cannot be bypassed by a load shape the
  # check doesn't know about.
  defp check_load_allowed!(path, internal_name, ctx) do
    LoadRestrictions.check!(path ++ [internal_name], ctx.load_restrictions)
  end

  # Determines whether a `:calculation_complex` field returns a resource type.
  defp calculation_returns_resource?(%Ash.Info.Manifest.Type{kind: kind})
       when kind in [:resource, :embedded_resource],
       do: true

  defp calculation_returns_resource?(%Ash.Info.Manifest.Type{kind: :array, item_type: item}) do
    case item do
      %Ash.Info.Manifest.Type{kind: kind} when kind in [:resource, :embedded_resource] -> true
      _ -> false
    end
  end

  defp calculation_returns_resource?(%Ash.Info.Manifest.Type{}), do: false

  defp format_extraction_template(template) do
    {atoms, keyword_pairs} =
      Enum.reduce(template, {[], []}, fn item, {atoms, kw_pairs} ->
        case item do
          {key, value} when is_atom(key) and is_map(value) ->
            {atoms, kw_pairs ++ [{key, value}]}

          {key, value} when is_atom(key) ->
            {atoms, kw_pairs ++ [{key, format_extraction_template(value)}]}

          atom when is_atom(atom) ->
            {atoms ++ [atom], kw_pairs}

          other ->
            {atoms ++ [other], kw_pairs}
        end
      end)

    atoms ++ keyword_pairs
  end

  # ---------------------------------------------------------------------------
  # Field validation helpers
  # ---------------------------------------------------------------------------

  # Validate a field exists in the fields list (list of %{name, type, ...}), throwing on failure
  defp validate_field_exists_in_fields!(name, fields, path, error_type) when is_list(fields) do
    unless Enum.any?(fields, fn f -> f.name == name end) do
      throw({:unknown_field, name, error_type, path})
    end
  end
end
