# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Pipeline do
  @moduledoc """
  Implements the four-stage pipeline:
  1. parse_request/4 - Parse and validate input with fail-fast
  2. execute_ash_action/1 - Execute Ash operations
  3. process_result/2 - Apply field selection
  4. format_output/2 - Format for client consumption

  ## Action shape

  Stage 1 resolves the `AshRpc.Entrypoint` and reads its action from the
  runtime's action lookup, so every downstream stage receives
  `%Ash.Info.Manifest.Action{}`.
  Consumers should rely on:

    * `action.inputs` — unified arguments + accepted attributes, each carrying
      a resolved `%Ash.Info.Manifest.Type{}` (no separate `:constraints` field;
      constraints are folded into the resolved type).
    * `action.returns` — `%Ash.Info.Manifest.Type{}` or `nil`.
    * `action.pagination` — `%Ash.Info.Manifest.Pagination{}` (uses `:countable?`,
      not `:countable`).
    * `action.metadata` — list of `%Ash.Info.Manifest.Metadata{}` whose `:type`
      is already resolved.

  Raw-Ash fields (`arguments`, `accept`, `constraints`, `allow_nil_input`,
  `require_attributes`) are NOT present. Use `AshRpc.Introspection.get_action!/3`
  for manifest lookups in runtime code paths instead of `Ash.Resource.Info.action/2`.
  """

  alias AshRpc.{
    ClientNames,
    ClientPath,
    FilterInput,
    InputFormatter,
    Request,
    RequestedFieldsProcessor,
    ResultProcessor,
    ValueFormatter
  }

  alias AshRpc.{ErrorFormatter, FieldFormatter, Introspection, LoadRestrictions}

  require Logger

  @page_keys [:limit, :offset, :count, :after, :before]

  @doc """
  Stage 1: Parse and validate request.

  Converts raw request parameters into a structured Request with validated fields.
  Fails fast on any invalid input - no permissive modes.
  """
  @spec parse_request(AshRpc.Runtime.t(), AshRpc.Context.t(), map(), keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def parse_request(runtime, %AshRpc.Context{} = ctx, params, opts \\ []) do
    validation_mode? = Keyword.get(opts, :validation_mode?, false)

    normalized_params =
      params
      |> resolve_param_keys(runtime)
      |> Map.put_new(:input, %{})

    with {:ok, entrypoint} <- discover_entrypoint(runtime, normalized_params, opts),
         :ok <- validate_tenant_param(normalized_params[:tenant]),
         ctx = AshRpc.Context.put_tenant_param(ctx, normalized_params[:tenant]),
         actor = ctx.actor,
         tenant = ctx.tenant,
         context = ctx.context,
         resource = entrypoint.resource,
         action =
           runtime
           |> Introspection.get_action!(resource, entrypoint.action)
           |> augment_action(entrypoint),
         load_restrictions = LoadRestrictions.normalize(entrypoint.load_restrictions),
         :ok <-
           validate_required_parameters_for_action_type(
             normalized_params,
             action,
             validation_mode?,
             runtime
           ),
         :ok <- validate_top_level_query_params(normalized_params, action, entrypoint),
         requested_fields = normalized_params[:fields] || [],
         {:ok, {select, load, template}} <-
           process_fields_unless_validation_mode(
             runtime,
             resource,
             action.name,
             requested_fields,
             validation_mode?,
             enable_filter?: entrypoint.enable_filter?,
             enable_sort?: entrypoint.enable_sort?,
             load_restrictions: load_restrictions
           ),
         {:ok, input} <- parse_action_input(normalized_params, action, resource, runtime),
         {:ok, get_by} <- parse_get_by(normalized_params, entrypoint, resource, runtime),
         {:ok, pagination} <- parse_pagination(normalized_params, runtime),
         {:ok, show_metadata} <-
           resolve_show_metadata(normalized_params[:metadata_fields], entrypoint, action, runtime) do
      {filter, filter_errors} = FilterInput.parse(runtime, resource, normalized_params[:filter])
      {sort, sort_errors} = FilterInput.parse_sort(runtime, resource, normalized_params[:sort])

      request =
        %Request{
          resource: resource,
          action: action,
          entrypoint: entrypoint,
          tenant: tenant,
          actor: actor,
          context: context,
          select: select,
          load: load,
          extraction_template: template,
          input: input,
          identity: normalized_params[:identity],
          get_by: get_by,
          filter: filter,
          sort: sort,
          pagination: pagination,
          show_metadata: show_metadata,
          query_errors: filter_errors ++ sort_errors,
          runtime: runtime
        }

      {:ok, request}
    else
      error -> error
    end
  end

  @doc """
  Stage 2: Execute Ash action using the parsed request.

  Builds the appropriate Ash query/changeset and executes it.
  Returns the raw Ash result for further processing.
  """
  @spec execute_ash_action(Request.t()) :: {:ok, term()} | {:error, term()}
  def execute_ash_action(%Request{} = request) do
    opts = [
      actor: request.actor,
      tenant: request.tenant,
      context: request.context
    ]

    case request.action.type do
      :read -> execute_read_action(request, opts)
      :create -> execute_create_action(request, opts)
      :update -> execute_update_action(request, opts)
      :destroy -> execute_destroy_action(request, opts)
      :action -> execute_generic_action(request, opts)
    end
  end

  @doc """
  Stage 3: Filter result fields using the extraction template.

  Applies field selection to the Ash result using the pre-computed template.
  Performance-optimized single-pass filtering.
  A generic action whose `returns` is untyped data (`Introspection.untyped_data_type?/2`:
  an unconstrained `:map`, `Ash.Type.Term`, or an array of either) returns its
  value unchanged: no field selection, no normalization.
  Handles metadata extraction for both read and mutation actions.
  If the extraction template is empty for mutation actions (create/update), returns empty data.
  """
  @spec process_result(term(), Request.t()) :: {:ok, term()} | {:error, term()}
  def process_result({:error, error}, %Request{}), do: {:error, error}

  def process_result(ash_result, %Request{} = request) do
    cond do
      untyped_return?(request.action, request.runtime) -> {:ok, ash_result}
      union_return(request.action, request.runtime) -> process_union_result(ash_result, request)
      true -> process_typed_result(ash_result, request)
    end
  end

  # A generic action whose declared return has no shape: its value is the response.
  defp untyped_return?(%{type: :action, returns: returns}, runtime),
    do: Introspection.untyped_data_type?(returns, runtime.type_lookup)

  defp untyped_return?(_action, _runtime), do: false

  # A generic action returning a union (`:single`) or an array of unions (`:array`).
  defp union_return(%{type: :action, returns: returns}, runtime) do
    case Introspection.classify_type(returns, runtime) do
      {:union, _type} ->
        :single

      {:array, item_type} ->
        if match?({:union, _}, Introspection.classify_type(item_type, runtime)), do: :array

      _ ->
        nil
    end
  end

  defp union_return(_action, _runtime), do: nil

  # The run must return `%Ash.Union{}` values: a bare member value doesn't say
  # which member it is, so it is reported instead of guessed.
  # A server-side bug, so it is logged; with the value's type only, since the
  # value may hold data the client must not see.
  defp process_union_result(result, %Request{} = request) do
    values =
      case union_return(request.action, request.runtime) do
        :single -> [result]
        :array -> if is_list(result), do: result, else: []
      end

    case Enum.filter(values, &bare_union_value?/1) do
      [value | _] ->
        Logger.error(
          "Generic action #{inspect(request.resource)}.#{request.action.name} " <>
            "(entrypoint #{request.entrypoint.name}) returned #{value_kind(value)} where its " <>
            "union return type needs an %Ash.Union{}"
        )

        {:error, {:invalid_union_return, request.entrypoint.name}}

      [] ->
        {:ok,
         ResultProcessor.extract_value(
           result,
           request.action.returns,
           [],
           request.extraction_template,
           request.runtime
         )}
    end
  end

  defp bare_union_value?(nil), do: false
  defp bare_union_value?(%Ash.Union{}), do: false
  defp bare_union_value?(_value), do: true

  defp value_kind(%module{}), do: "a #{inspect(module)} struct"
  defp value_kind(value) when is_binary(value), do: "a string"
  defp value_kind(value) when is_integer(value), do: "an integer"
  defp value_kind(value) when is_float(value), do: "a float"
  defp value_kind(value) when is_atom(value), do: "an atom"
  defp value_kind(value) when is_map(value), do: "a map"
  defp value_kind(value) when is_list(value), do: "a list"
  defp value_kind(value) when is_tuple(value), do: "a tuple"
  defp value_kind(_value), do: "a non-union value"

  defp process_typed_result(ash_result, %Request{} = request) do
    case ash_result do
      result when is_list(result) or is_map(result) or is_tuple(result) ->
        # For mutations with no field selection, use empty data
        # (metadata can still be added on top)
        is_mutation_with_no_fields =
          request.extraction_template == [] and
            request.action.type in [:create, :update, :destroy]

        if is_mutation_with_no_fields and Enum.empty?(request.show_metadata) do
          {:ok, %{}}
        else
          filtered =
            cond do
              is_mutation_with_no_fields ->
                %{}

              # Plain map data carries no type to dispatch on, so typed map
              # returns are extracted against the declared `action.returns`
              # (otherwise nested arrays/embedded resources come back whole).
              typed_map_return?(request.action, request.runtime) ->
                ResultProcessor.extract_value(
                  result,
                  request.action.returns,
                  [],
                  request.extraction_template,
                  request.runtime
                )

              true ->
                ResultProcessor.process(
                  result,
                  request.extraction_template,
                  get_field_mapping_module(request.action, request.resource, request.runtime),
                  request.runtime
                )
            end

          filtered_with_metadata = add_metadata(filtered, result, request)

          {:ok, filtered_with_metadata}
        end

      primitive_value ->
        {:ok, ResultProcessor.normalize_primitive(primitive_value, request.runtime)}
    end
  end

  # Determines the module to use for field name mapping based on action return type
  # Returns:
  # - resource module for resource-returning actions
  # - TypedStruct module for typed_struct returns (if it has client-name overrides)
  # - request.resource as fallback for CRUD actions
  defp get_field_mapping_module(action, default_resource, runtime) do
    if action.type != :action do
      default_resource
    else
      case Introspection.return_classification(action, runtime.type_lookup) do
        {:ok, type, resource_module} when type in [:resource, :array_of_resource] ->
          resource_module

        {:ok, type, {module, _fields}} when type in [:typed_struct, :array_of_typed_struct] ->
          if is_nil(Introspection.type_field_name_overrides(runtime, module)),
            do: nil,
            else: module

        _ ->
          default_resource
      end
    end
  end

  @doc """
  Stage 4: Format output for client consumption.

  Applies output field formatting and final response structure.

  `format_response/2` handles failures raised before a `%Request{}` exists (action
  discovery, identity resolution, parameter validation); errors are formatted the
  same way as in `format_output/2` so both paths agree on the response shape.
  """
  def format_response(runtime, %{success: false, errors: _} = filtered_result) do
    format_output_data(filtered_result, runtime.output_formatter, nil)
  end

  @doc false
  def error_response(runtime, reason, scope) do
    errors = runtime |> AshRpc.ErrorBuilder.build_error_response(reason, scope) |> List.wrap()
    format_response(runtime, %{success: false, errors: errors})
  end

  @doc false
  def error_scope(%Request{} = r),
    do: %{
      domain: r.entrypoint.domain,
      resource: r.resource,
      action: r.action.name,
      context: r.context,
      selection: ClientPath.selection_root(r.runtime, r.resource, r.action)
    }

  @doc false
  # For a parse_request failure: only where field-selection paths start, so
  # ErrorBuilder can name them; nil before the entrypoint resolves. Ash errors
  # keep the unscoped handling they get today (no domain).
  def parse_error_scope(runtime, params, opts) when is_map(params) do
    case parse_error_entrypoint(runtime, params, opts) do
      %AshRpc.Entrypoint{resource: resource, action: action} ->
        action_struct = Map.get(runtime.action_lookup, {resource, action})
        %{selection: ClientPath.selection_root(runtime, resource, action_struct)}

      _ ->
        nil
    end
  end

  def parse_error_scope(_runtime, _params, _opts), do: nil

  defp parse_error_entrypoint(runtime, params, opts) do
    case Keyword.fetch(opts, :entrypoint) do
      {:ok, %AshRpc.Entrypoint{} = entrypoint} ->
        entrypoint

      _ ->
        case params |> resolve_param_keys(runtime) |> Map.get(:action) do
          name when is_binary(name) -> Map.get(runtime.entrypoints, name)
          _ -> nil
        end
    end
  end

  @doc """
  Stage 4: Format output for client consumption with type awareness.

  Applies type-aware output field formatting and final response structure.
  """
  def format_output(filtered_result, %Request{} = request) do
    format_output_data(filtered_result, request.runtime.output_formatter, request)
  end

  defp discover_entrypoint(runtime, params, opts) do
    case Keyword.fetch(opts, :entrypoint) do
      {:ok, %AshRpc.Entrypoint{} = entrypoint} ->
        {:ok, entrypoint}

      :error ->
        case params[:action] do
          name when name in [nil, ""] ->
            {:error, {:missing_required_parameter, :action}}

          name when is_binary(name) or is_atom(name) ->
            case Map.fetch(runtime.entrypoints, to_string(name)) do
              {:ok, entrypoint} -> {:ok, entrypoint}
              :error -> {:error, {:action_not_found, name}}
            end

          name ->
            {:error, {:invalid_action_type, name}}
        end
    end
  end

  # The `tenant` request param is passed to Ash, which converts strings,
  # integers and atoms (`Ash.ToTenant`); anything else can't be a tenant.
  # The transport tenant is not a request param and is not checked.
  defp validate_tenant_param(tenant)
       when is_binary(tenant) or is_integer(tenant) or is_atom(tenant),
       do: :ok

  defp validate_tenant_param(tenant), do: {:error, {:invalid_tenant_type, tenant}}

  defp augment_action(action, %AshRpc.Entrypoint{get?: get?, get_by: get_by}) do
    if get? or get_by != [], do: %{action | get?: true}, else: action
  end

  # Top-level keys resolve through the :params vocabulary; a miss is dropped,
  # as an unknown key always was. Values are left as sent.
  defp resolve_param_keys(params, runtime) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      case ClientNames.vocabulary(runtime, :params, key) do
        {:ok, name} -> Map.put(acc, name, value)
        :error -> acc
      end
    end)
  end

  # {resolved, misses-as-sent}
  defp resolve_keys(map, resolve) do
    {resolved, misses} =
      Enum.reduce(map, {%{}, []}, fn {key, value}, {acc, misses} ->
        case resolve.(key) do
          {:ok, name} -> {Map.put(acc, name, value), misses}
          :error -> {acc, [key | misses]}
        end
      end)

    {resolved, Enum.reverse(misses)}
  end

  # Requested names resolve by exact lookup among the exposed fields' client
  # names. A miss (another casing, a field the entrypoint doesn't expose, or
  # any name when nothing is exposed) is an error listing the allowed names.
  defp resolve_show_metadata(requested, entrypoint, _action, runtime)
       when is_list(requested) and requested != [] do
    exposed = entrypoint.exposed_metadata_fields
    names = client_metadata_names(entrypoint, runtime)

    {fields, unknown} =
      Enum.reduce(requested, {[], []}, fn entry, {fields, unknown} ->
        case metadata_field(entry, names) do
          {:ok, field} -> {[field | fields], unknown}
          :error -> {fields, [entry | unknown]}
        end
      end)

    case unknown do
      [] ->
        {:ok, fields |> Enum.reverse() |> Enum.filter(&(&1 in exposed))}

      _ ->
        allowed = for field <- exposed, {client, ^field} <- names, do: client
        {:error, {:unknown_metadata_fields, Enum.reverse(unknown), allowed}}
    end
  end

  defp resolve_show_metadata(requested, _entrypoint, _action, _runtime)
       when not is_list(requested) and not is_nil(requested),
       do: {:error, {:invalid_metadata_fields_type, requested}}

  defp resolve_show_metadata(_requested, entrypoint, action, _runtime) do
    exposed = entrypoint.exposed_metadata_fields

    if Introspection.metadata_enabled?(exposed) and action.type in [:create, :update, :destroy],
      do: {:ok, exposed},
      else: {:ok, []}
  end

  # Wire entrypoints carry the decorated reverse map. An entrypoint passed with
  # the `entrypoint:` option never went through the decorator, so its names are
  # built here from the same overrides and output formatter.
  defp client_metadata_names(%AshRpc.Entrypoint{client_metadata_field_names: names}, _runtime)
       when map_size(names) > 0,
       do: names

  defp client_metadata_names(%AshRpc.Entrypoint{} = entrypoint, runtime) do
    Map.new(entrypoint.exposed_metadata_fields, fn field ->
      {Map.get(entrypoint.metadata_field_names, field) ||
         FieldFormatter.format_field_name(field, runtime.output_formatter), field}
    end)
  end

  # Atom names come from server-side callers that already hold internal names.
  # JSON null and booleans decode to atoms but are not names.
  defp metadata_field(field, _names)
       when is_atom(field) and not is_boolean(field) and not is_nil(field),
       do: {:ok, field}

  defp metadata_field(field, names) when is_binary(field), do: Map.fetch(names, field)
  defp metadata_field(_field, _names), do: :error

  defp parse_action_input(params, action, resource, runtime) do
    raw_input = Map.get(params, :input, %{})

    if is_map(raw_input) do
      case InputFormatter.format(raw_input, resource, action, runtime) do
        {:ok, parsed_input} ->
          converted_input =
            convert_keyword_tuple_inputs(parsed_input, resource, action, runtime)

          {:ok, converted_input}

        {:error, _} = error ->
          error
      end
    else
      {:error, {:invalid_input_format, raw_input}}
    end
  end

  defp convert_keyword_tuple_inputs(input, resource, action, runtime) do
    Enum.reduce(input, %{}, fn {key, value}, acc ->
      type_result = find_input_type(key, resource, action, runtime)

      case type_result do
        {:tuple, constraints} ->
          converted_value = convert_map_to_tuple(value, constraints)
          Map.put(acc, key, converted_value)

        {:keyword, constraints} ->
          converted_value = convert_map_to_keyword(value, constraints)
          Map.put(acc, key, converted_value)

        _ ->
          Map.put(acc, key, value)
      end
    end)
  end

  # Input keys are internal atoms after InputFormatter.
  defp find_input_type(field_name, resource, action, runtime) do
    if is_atom(field_name) do
      case lookup_field_type(resource, field_name, runtime) do
        nil -> find_action_argument_type(field_name, action, runtime)
        type -> classify_tuple_or_keyword_type(type, runtime)
      end
    else
      :other
    end
  end

  defp find_action_argument_type(field_atom, action, runtime) do
    case Enum.find(action.inputs, &(&1.name == field_atom)) do
      %{type: %Ash.Info.Manifest.Type{} = type_info} ->
        classify_tuple_or_keyword_type(type_info, runtime)

      _ ->
        :other
    end
  end

  # Classifies a manifest type as tuple, keyword, or other, following `:type_ref`
  # references to the named definition in the type lookup.
  defp classify_tuple_or_keyword_type(%Ash.Info.Manifest.Type{kind: :tuple} = type_info, _runtime) do
    {:tuple, type_info}
  end

  defp classify_tuple_or_keyword_type(
         %Ash.Info.Manifest.Type{kind: :keyword} = type_info,
         _runtime
       ) do
    {:keyword, type_info}
  end

  defp classify_tuple_or_keyword_type(
         %Ash.Info.Manifest.Type{kind: :type_ref, module: module},
         runtime
       ) do
    runtime.type_lookup
    |> Ash.Info.Manifest.get_type!(module)
    |> classify_tuple_or_keyword_type(runtime)
  end

  defp classify_tuple_or_keyword_type(%Ash.Info.Manifest.Type{}, _runtime), do: :other

  defp convert_map_to_tuple(value, type_info_or_constraints) when is_map(value) do
    field_order = get_tuple_field_names(type_info_or_constraints)

    tuple_values =
      Enum.map(field_order, fn field_name ->
        string_key = if is_atom(field_name), do: Atom.to_string(field_name), else: field_name

        # Map.fetch, not ||: a legitimate `false` or `nil` value must not fall
        # through to the other key form.
        case Map.fetch(value, field_name) do
          {:ok, field_value} -> field_value
          :error -> Map.get(value, string_key)
        end
      end)

    List.to_tuple(tuple_values)
  end

  defp convert_map_to_tuple(value, _type_info_or_constraints), do: value

  defp convert_map_to_keyword(value, type_info_or_constraints) when is_map(value) do
    allowed_fields = get_tuple_field_names(type_info_or_constraints) |> MapSet.new()

    # Keys were resolved by ValueFormatter, so a string key is not a field.
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      unless is_atom(key) and MapSet.member?(allowed_fields, key) do
        raise ArgumentError,
              "Invalid keyword field: #{inspect(key)}. Allowed fields: #{inspect(MapSet.to_list(allowed_fields))}"
      end

      Map.put(acc, key, val)
    end)
  end

  defp convert_map_to_keyword(value, _type_info_or_constraints), do: value

  defp get_tuple_field_names(%Ash.Info.Manifest.Type{fields: fields})
       when is_list(fields) and fields != [] do
    Enum.map(fields, & &1.name)
  end

  defp get_tuple_field_names(%Ash.Info.Manifest.Type{element_types: ets})
       when is_list(ets) and ets != [] do
    Enum.map(ets, & &1.name)
  end

  defp get_tuple_field_names(_), do: []

  defp parse_get_by(params, entrypoint, resource, runtime) do
    rpc_get_by = entrypoint.get_by

    cond do
      rpc_get_by == [] and is_nil(params[:get_by]) ->
        {:ok, nil}

      # Present (an empty map included) where the entrypoint has no get_by
      # fields: it would otherwise be ignored.
      rpc_get_by == [] ->
        {:error, {:get_by_not_supported, :top_level, :unsupported}}

      true ->
        case params[:get_by] || %{} do
          raw_get_by when is_map(raw_get_by) and not is_struct(raw_get_by) ->
            resolve_get_by(raw_get_by, rpc_get_by, resource, runtime)

          raw_get_by ->
            {:error, {:invalid_get_by_format, raw_get_by}}
        end
    end
  end

  defp resolve_get_by(raw_get_by, rpc_get_by, resource, runtime) do
    output_formatter = runtime.output_formatter
    res_struct = Map.get(runtime.resource_lookup, resource)

    {parsed_get_by, unknown} =
      resolve_keys(raw_get_by, &ClientNames.resource_field(runtime, resource, &1))

    allowed_fields = MapSet.new(rpc_get_by)
    provided_fields = parsed_get_by |> Map.keys() |> MapSet.new()

    missing_fields = MapSet.difference(allowed_fields, provided_fields) |> MapSet.to_list()

    extra_fields =
      (MapSet.difference(provided_fields, allowed_fields) |> MapSet.to_list()) ++ unknown

    cond do
      not Enum.empty?(extra_fields) ->
        # Unknown keys are reported as sent.
        formatted_extra =
          Enum.map(extra_fields, fn
            name when is_binary(name) -> name
            name -> FieldFormatter.format_field_for_client(name, res_struct, output_formatter)
          end)

        formatted_allowed =
          Enum.map(
            rpc_get_by,
            &FieldFormatter.format_field_for_client(&1, res_struct, output_formatter)
          )

        {:error, {:unexpected_get_by_fields, formatted_extra, formatted_allowed}}

      not Enum.empty?(missing_fields) ->
        formatted_missing =
          Enum.map(
            missing_fields,
            &FieldFormatter.format_field_for_client(&1, res_struct, output_formatter)
          )

        {:error, {:missing_get_by_fields, formatted_missing}}

      true ->
        validated_get_by =
          Enum.reduce(rpc_get_by, %{}, fn field, acc ->
            value = Map.get(parsed_get_by, field)

            if lookup_field_exists?(resource, field, runtime) do
              Map.put(acc, field, value)
            else
              acc
            end
          end)

        validate_scalar_get_by(validated_get_by, res_struct, output_formatter)
    end
  end

  # Top-level filter/sort/page must error when explicitly present but unusable
  # Absent params never error; `page: %{}` counts as present. Nested envelopes are unaffected: their
  # gating is flags-only and handled in the FieldSelector.
  defp validate_top_level_query_params(params, action, entrypoint) do
    list_read? = action.type == :read and not action.get?

    with :ok <-
           validate_top_level_param(
             params[:filter],
             list_read?,
             entrypoint.enable_filter?,
             :filter_not_supported
           ),
         :ok <-
           validate_top_level_param(
             params[:sort],
             list_read?,
             entrypoint.enable_sort?,
             :sort_not_supported
           ) do
      validate_top_level_page(params[:page], list_read?, action)
    end
  end

  defp validate_top_level_param(nil, _list_read?, _enabled?, _error), do: :ok

  defp validate_top_level_param(_present, list_read?, enabled?, error) do
    cond do
      not list_read? -> {:error, {error, :top_level, :unsupported}}
      not enabled? -> {:error, {error, :top_level, :disabled}}
      true -> :ok
    end
  end

  defp validate_top_level_page(nil, _list_read?, _action), do: :ok

  defp validate_top_level_page(_present, list_read?, action) do
    if list_read? and Introspection.action_supports_pagination?(action) do
      :ok
    else
      {:error, {:pagination_not_supported, :top_level, :unsupported}}
    end
  end

  defp parse_pagination(params, runtime) do
    case params[:page] do
      nil ->
        {:ok, nil}

      page when is_map(page) ->
        {parsed, misses} = resolve_keys(page, &ClientNames.vocabulary(runtime, :page, &1))

        case misses ++ (Map.keys(parsed) -- @page_keys) do
          [] -> {:ok, parsed}
          unknown_keys -> {:error, {:unknown_page_keys, unknown_keys}}
        end

      invalid ->
        {:error, {:invalid_pagination, invalid}}
    end
  end

  defp execute_read_action(%Request{} = request, opts) do
    if request.action.get? do
      query =
        request.resource
        |> Ash.Query.for_read(request.action.name, request.input, opts)
        |> apply_select_and_load(request)
        |> apply_get_by_filter(request.get_by)

      not_found_error? = request.entrypoint.not_found_error?

      case Ash.read_one(query) do
        {:ok, nil} when not_found_error? ->
          not_found(request)

        result ->
          result
      end
    else
      query =
        request.resource
        |> Ash.Query.for_read(request.action.name, request.input, opts)
        |> apply_select_and_load(request)
        |> apply_filter(request.filter)
        |> apply_sort(request.sort)
        |> apply_pagination(request.pagination)
        |> add_query_errors(request.query_errors)

      Ash.read(query)
    end
  end

  defp execute_create_action(%Request{} = request, opts) do
    request.resource
    |> Ash.Changeset.for_create(request.action.name, request.input, opts)
    |> Ash.Changeset.select(request.select)
    |> Ash.Changeset.load(request.load)
    |> Ash.create()
  end

  defp execute_update_action(%Request{} = request, opts) do
    with {:ok, query} <- target_query(request, opts) do
      case Ash.bulk_update(query, request.action.name, request.input, bulk_opts(request, opts)) do
        %Ash.BulkResult{status: :success, records: [record]} ->
          {:ok, record}

        %Ash.BulkResult{status: :success, records: []} ->
          not_found(request)

        result ->
          bulk_error(result)
      end
    end
  end

  defp execute_destroy_action(%Request{} = request, opts) do
    with {:ok, query} <- target_query(request, opts) do
      case Ash.bulk_destroy(query, request.action.name, request.input, bulk_opts(request, opts)) do
        %Ash.BulkResult{status: :success, records: [record]} -> {:ok, record}
        %Ash.BulkResult{status: :success, records: []} -> not_found(request)
        result -> bulk_error(result)
      end
    end
  end

  @doc false
  # The single-record update/destroy target: a query narrowed to the requested
  # identity (none for an `identities: []` entrypoint, whose read action scopes
  # it). `run_action` runs the bulk action over it; `AshRpc.Validation` reads
  # the record from it. `{:error, reason}` is a pipeline reason.
  @spec target_query(Request.t(), keyword()) :: {:ok, Ash.Query.t()} | {:error, term()}
  def target_query(%Request{} = request, opts) do
    request.resource
    |> Ash.Query.set_tenant(opts[:tenant])
    |> Ash.Query.set_context(opts[:context] || %{})
    |> maybe_apply_identity_filter(
      request.identity,
      request.entrypoint.identities,
      request.runtime
    )
    |> case do
      {:ok, query} -> {:ok, Ash.Query.limit(query, 1)}
      error -> error
    end
  end

  defp bulk_opts(%Request{} = request, opts) do
    bulk_opts = [
      return_errors?: true,
      notify?: true,
      strategy: [:atomic, :stream, :atomic_batches],
      allow_stream_with: :full_read,
      authorize_changeset_with: authorize_bulk_with(request.runtime, request.resource),
      return_records?: true,
      tenant: opts[:tenant],
      context: opts[:context] || %{},
      actor: opts[:actor],
      domain: request.entrypoint.domain,
      # The bulk action applies select/load to the returned records; select/load
      # set on the target query are not carried over to them.
      select: request.select,
      load: request.load
    ]

    case request.entrypoint.read_action do
      nil -> bulk_opts
      read_action -> Keyword.put(bulk_opts, :read_action, read_action)
    end
  end

  defp bulk_error(%Ash.BulkResult{errors: errors}) when errors != [],
    do: {:error, Enum.map(errors, &drop_batch_index/1)}

  defp bulk_error(other), do: {:error, other}

  # A get, update or destroy whose target query matched no record.
  defp not_found(%Request{} = request),
    do: {:error, Ash.Error.Query.NotFound.exception(resource: request.resource)}

  # Ash prefixes bulk errors' paths with the record's index in the batch. The
  # bulk action here always targets one record, so the index means nothing to
  # the client and is dropped, from an error class's inner errors too.
  defp drop_batch_index(error), do: error |> drop_path_index() |> drop_inner_batch_index()

  defp drop_path_index(%{path: [index | rest]} = error) when is_integer(index),
    do: %{error | path: rest}

  defp drop_path_index(error), do: error

  defp drop_inner_batch_index(%{errors: [_ | _] = inner} = error),
    do: %{error | errors: Enum.map(inner, &drop_batch_index/1)}

  defp drop_inner_batch_index(error), do: error

  defp execute_generic_action(%Request{} = request, opts) do
    action_result =
      request.resource
      |> Ash.ActionInput.for_action(request.action.name, request.input, opts)
      |> Ash.run_action()

    case action_result do
      {:ok, result} ->
        returns_resource? =
          case Introspection.return_classification(request.action, request.runtime.type_lookup) do
            {:ok, :resource, _} -> true
            {:ok, :array_of_resource, _} -> true
            _ -> false
          end

        if returns_resource? and not Enum.empty?(request.load) do
          Ash.load(result, request.load, opts)
        else
          action_result
        end

      :ok ->
        {:ok, %{}}

      _ ->
        action_result
    end
  end

  # Filter and sort names that aren't client names (AshRpc.FilterInput).
  defp add_query_errors(query, []), do: query
  defp add_query_errors(query, errors), do: Ash.Query.add_error(query, errors)

  defp apply_filter(query, nil), do: query
  defp apply_filter(query, filter), do: Ash.Query.filter_input(query, filter)

  defp apply_get_by_filter(query, nil), do: query

  defp apply_get_by_filter(query, get_by) when is_map(get_by) do
    Ash.Query.do_filter(query, Map.to_list(get_by))
  end

  # See non_scalar_keys/2: get_by lookups are equality-only.
  defp validate_scalar_get_by(get_by, res_struct, output_formatter) do
    case non_scalar_keys(get_by, res_struct, output_formatter) do
      [] -> {:ok, get_by}
      keys -> {:error, {:invalid_get_by, %{non_scalar_keys: keys}}}
    end
  end

  defp apply_sort(query, nil), do: query
  defp apply_sort(query, sort), do: Ash.Query.sort_input(query, sort)

  defp apply_pagination(query, nil), do: Ash.Query.page(query, nil)
  defp apply_pagination(query, page), do: Ash.Query.page(query, Map.to_list(page))

  defp format_output_data(%{success: true, data: result_data} = result, formatter, request) do
    {actual_data, metadata} =
      if is_map(result_data) and Map.has_key?(result_data, :data) and
           Map.has_key?(result_data, :metadata) do
        {result_data.data, result_data.metadata}
      else
        {result_data, Map.get(result, :metadata)}
      end

    # Determine how to format the output based on action return type
    formatted_data =
      format_action_output(
        actual_data,
        request.action,
        request.resource,
        request.runtime
      )

    base_response = %{
      FieldFormatter.format_field_name("success", formatter) => true,
      FieldFormatter.format_field_name("data", formatter) => formatted_data
    }

    case metadata do
      nil ->
        base_response

      # Already keyed by client names and formatted (format_metadata/2).
      meta when is_map(meta) ->
        Map.put(base_response, FieldFormatter.format_field_name("metadata", formatter), meta)
    end
  end

  defp format_output_data(%{success: false, errors: errors}, formatter, _request) do
    formatted_errors = Enum.map(errors, &ErrorFormatter.format(&1, formatter))

    %{
      FieldFormatter.format_field_name("success", formatter) => false,
      FieldFormatter.format_field_name("errors", formatter) => formatted_errors
    }
  end

  defp format_output_data(%{success: true}, formatter, _request) do
    %{
      FieldFormatter.format_field_name("success", formatter) => true
    }
  end

  # Formats action output based on action return type
  # - Resource-returning actions are formatted against the resource (pages too)
  # - Composite types (typed maps, typed structs) use ValueFormatter with type constraints
  # - Untyped data (`untyped_return?/2`) is passed through unchanged — the action
  #   opted out of typing, so its keys are the caller's responsibility and must
  #   not be renamed
  defp format_action_output(data, action, default_resource, runtime) do
    cond do
      action.type != :action ->
        format_resource_output(data, default_resource, runtime)

      untyped_return?(action, runtime) ->
        data

      true ->
        case Introspection.return_classification(action, runtime.type_lookup) do
          {:ok, type, resource_module} when type in [:resource, :array_of_resource] ->
            format_resource_output(data, resource_module, runtime)

          _ ->
            format_generic_action_output(data, action, runtime)
        end
    end
  end

  # Page keys (count, limit, …) are pagination metadata, not resource fields;
  # only the results are formatted against the resource.
  defp format_resource_output(%{type: page_type} = page, resource, runtime)
       when page_type in [:offset, :keyset] and not is_struct(page) do
    Enum.into(page, %{}, fn
      {:results, results} when is_list(results) ->
        {FieldFormatter.format_field_name(:results, runtime.output_formatter),
         format_resource_output(results, resource, runtime)}

      {key, value} ->
        {FieldFormatter.format_field_name(key, runtime.output_formatter), value}
    end)
  end

  defp format_resource_output(list, resource, runtime) when is_list(list),
    do: Enum.map(list, &format_resource_output(&1, resource, runtime))

  defp format_resource_output(data, resource, runtime) do
    type = %Ash.Info.Manifest.Type{kind: :resource, module: resource, resource_module: resource}
    ValueFormatter.format(data, type, [], :output, runtime)
  end

  defp format_generic_action_output(data, action, runtime) do
    ValueFormatter.format(data, action.returns, [], :output, runtime)
  end

  defp typed_map_return?(action, runtime) do
    case Introspection.return_classification(action, runtime.type_lookup) do
      {:ok, type, _} when type in [:typed_map, :array_of_typed_map] -> true
      _ -> false
    end
  end

  defp validate_required_parameters_for_action_type(params, action, validation_mode?, runtime) do
    needs_fields =
      if validation_mode? do
        false
      else
        case action.type do
          :read ->
            true

          type when type in [:create, :update, :destroy] ->
            false

          :action ->
            case Introspection.return_classification(action, runtime.type_lookup) do
              {:ok, type, _} when type in [:unconstrained_map, :array_of_unconstrained_map] ->
                false

              {:ok, _, _} ->
                true

              _ ->
                false
            end

          _ ->
            false
        end
      end

    validate_fields_if_needed(params, needs_fields)
  end

  # In validation mode with no fields, skip field processing and return empty result
  defp process_fields_unless_validation_mode(
         _runtime,
         _resource,
         _action_name,
         [],
         true = _validation_mode?,
         _opts
       ) do
    {:ok, {[], [], []}}
  end

  defp process_fields_unless_validation_mode(
         runtime,
         resource,
         action_name,
         requested_fields,
         _validation_mode?,
         opts
       ) do
    RequestedFieldsProcessor.process(runtime, resource, action_name, requested_fields, opts)
  end

  # `fields` is optional here, but when sent it must be a list.
  defp validate_fields_if_needed(params, false) do
    case params[:fields] do
      fields when is_nil(fields) or is_list(fields) -> :ok
      fields -> {:error, {:invalid_fields_type, fields}}
    end
  end

  defp validate_fields_if_needed(params, true) do
    fields = params[:fields]

    cond do
      is_nil(fields) ->
        {:error, {:missing_required_parameter, :fields}}

      not is_list(fields) ->
        {:error, {:invalid_fields_type, fields}}

      Enum.empty?(fields) ->
        {:error, {:empty_fields_array, fields}}

      true ->
        :ok
    end
  end

  defp maybe_apply_identity_filter(query, _identity, [], _runtime), do: {:ok, query}

  defp maybe_apply_identity_filter(query, identity, identities, runtime)
       when not is_nil(identity) do
    resource = query.resource

    with {:ok, filter} <- build_identity_filter(resource, identity, identities, runtime),
         :ok <- validate_scalar_identity_filter(filter, resource, runtime) do
      {:ok, Ash.Query.do_filter(query, filter)}
    end
  end

  # Identity is nil but identities list is not empty - this means identity is required but missing
  defp maybe_apply_identity_filter(query, nil, identities, runtime) do
    resource = query.resource
    output_formatter = runtime.output_formatter
    res_struct = Map.get(runtime.resource_lookup, resource)

    expected_keys =
      resource
      |> get_expected_identity_keys(identities, runtime)
      |> Enum.map(&FieldFormatter.format_field_for_client(&1, res_struct, output_formatter))

    {:error,
     {:missing_identity,
      %{
        expected_keys: expected_keys,
        identities: identities
      }}}
  end

  # The keys must be exactly one identity's keys (by client name): a key that
  # is not a client name, or one outside the identity, matches none.
  defp build_identity_filter(resource, identity, identities, runtime) when is_map(identity) do
    parsed_identity = parse_identity_input(resource, identity, runtime)
    provided = parsed_identity |> Map.keys() |> MapSet.new()

    result =
      Enum.find_value(identities, fn
        :_primary_key ->
          primary_key_attrs = lookup_primary_key(resource, runtime)

          if length(primary_key_attrs) > 1 &&
               MapSet.equal?(provided, MapSet.new(primary_key_attrs)) do
            {:ok, Enum.map(primary_key_attrs, &{&1, Map.fetch!(parsed_identity, &1)})}
          else
            nil
          end

        identity_name ->
          identity_info = lookup_identity(resource, identity_name, runtime)

          if identity_info && MapSet.equal?(provided, MapSet.new(identity_info.keys)) do
            {:ok, Enum.map(identity_info.keys, &{&1, Map.fetch!(parsed_identity, &1)})}
          else
            nil
          end
      end)

    case result do
      {:ok, filter} ->
        {:ok, filter}

      nil ->
        output_formatter = runtime.output_formatter
        res_struct = Map.get(runtime.resource_lookup, resource)

        # The keys as sent; an atom key (a server-side caller) takes its
        # decorated client name.
        provided_keys =
          identity
          |> Map.keys()
          |> Enum.map(fn
            key when is_binary(key) -> key
            key -> FieldFormatter.format_field_for_client(key, res_struct, output_formatter)
          end)

        expected_keys =
          resource
          |> get_expected_identity_keys(identities, runtime)
          |> Enum.map(&FieldFormatter.format_field_for_client(&1, res_struct, output_formatter))

        {:error,
         {:invalid_identity,
          %{
            provided_keys: provided_keys,
            expected_keys: expected_keys,
            identities: identities
          }}}
    end
  end

  # A primary key passed directly. A composite primary key must be a map: a
  # scalar would match on its first field only.
  defp build_identity_filter(resource, identity, identities, runtime)
       when not is_nil(identity) do
    primary_key = lookup_primary_key(resource, runtime)

    cond do
      :_primary_key in identities and length(primary_key) > 1 ->
        res_struct = Map.get(runtime.resource_lookup, resource)

        expected_keys =
          Enum.map(
            primary_key,
            &FieldFormatter.format_field_for_client(&1, res_struct, runtime.output_formatter)
          )

        {:error, {:invalid_identity, %{composite_primary_key: expected_keys}}}

      :_primary_key in identities ->
        {:ok, [{List.first(primary_key), identity}]}

      true ->
        {:error,
         {:invalid_identity,
          %{
            message: "Primary key identity not allowed for this action",
            identities: identities
          }}}
    end
  end

  defp get_expected_identity_keys(resource, identities, runtime) do
    Enum.flat_map(identities, fn
      :_primary_key ->
        lookup_primary_key(resource, runtime)

      identity_name ->
        case lookup_identity(resource, identity_name, runtime) do
          nil -> []
          identity -> identity.keys
        end
    end)
    |> Enum.uniq()
  end

  defp lookup_primary_key(resource, runtime) do
    Ash.Info.Manifest.primary_key(runtime.resource_lookup, resource)
  end

  defp lookup_identity(resource, identity_name, runtime) do
    Ash.Info.Manifest.get_identity(runtime.resource_lookup, resource, identity_name)
  end

  defp lookup_field_exists?(resource, field_name, runtime) do
    case Ash.Info.Manifest.get_resource(runtime.resource_lookup, resource) do
      %Ash.Info.Manifest.Resource{} = r -> Ash.Info.Manifest.Resource.has_field?(r, field_name)
      nil -> false
    end
  end

  defp lookup_field_type(resource, field_name, runtime) do
    case Ash.Info.Manifest.get_field(runtime.resource_lookup, resource, field_name) do
      %Ash.Info.Manifest.Field{type: %Ash.Info.Manifest.Type{} = type} -> type
      _ -> nil
    end
  end

  # Identity keys resolve to resource fields by client name; a miss keeps the
  # client's string, so it matches no identity.
  defp parse_identity_input(resource, identity, runtime) when is_map(identity) do
    Map.new(identity, fn {key, value} ->
      case ClientNames.resource_field(runtime, resource, key) do
        {:ok, field} -> {field, value}
        :error -> {key, value}
      end
    end)
  end

  # See non_scalar_keys/2: identity lookups are equality-only.
  defp validate_scalar_identity_filter(filter, resource, runtime) do
    res_struct = Map.get(runtime.resource_lookup, resource)

    case non_scalar_keys(filter, res_struct, runtime.output_formatter) do
      [] -> :ok
      keys -> {:error, {:invalid_identity, %{non_scalar_keys: keys}}}
    end
  end

  # Identity, primary-key and get_by values are applied through the *trusted*
  # filter API (Ash.Query.do_filter/2), so a map or list value would be
  # interpreted as an operator expression (e.g. `%{"greater_than" => ""}` =>
  # `field > ""`) instead of an equality match, turning an exact-key lookup into
  # an arbitrary predicate. JSON input only ever yields
  # string/number/boolean/nil/list/map, so "not a map and not a list" cleanly
  # rejects operator maps while preserving legitimate operands (including false).
  # Returns the offending keys by their decorated client names ([] if all are
  # scalar).
  defp non_scalar_keys(pairs, res_struct, output_formatter) do
    for {key, value} <- pairs, not scalar_identity_value?(value) do
      FieldFormatter.format_field_for_client(key, res_struct, output_formatter)
    end
  end

  defp scalar_identity_value?(value), do: not (is_map(value) or is_list(value))

  defp authorize_bulk_with(runtime, resource) do
    case AshRpc.Manifest.Custom.authorize_bulk_strategy(
           Map.get(runtime.resource_lookup, resource)
         ) do
      nil ->
        if Ash.DataLayer.data_layer_can?(resource, :expr_error), do: :error, else: :filter

      strategy ->
        strategy
    end
  end

  defp apply_select_and_load(query, request) do
    query =
      if request.select && request.select != [] do
        Ash.Query.select(query, request.select)
      else
        query
      end

    if request.load && request.load != [] do
      Ash.Query.load(query, request.load)
    else
      query
    end
  end

  defp add_metadata(filtered_result, original_result, %Request{} = request) do
    if Enum.empty?(request.show_metadata) do
      filtered_result
    else
      case request.action.type do
        :read ->
          add_read_metadata(filtered_result, original_result, request)

        action_type when action_type in [:create, :update, :destroy] ->
          add_mutation_metadata(filtered_result, original_result, request)

        _ ->
          filtered_result
      end
    end
  end

  defp add_read_metadata(filtered_result, original_result, request)
       when is_list(filtered_result) do
    if is_list(original_result) do
      Enum.zip(filtered_result, original_result)
      |> Enum.map(fn {filtered_record, original_record} ->
        do_add_read_metadata(filtered_record, original_record, request)
      end)
    else
      filtered_result
    end
  end

  defp add_read_metadata(filtered_result, original_result, request)
       when is_map(filtered_result) do
    if Map.has_key?(filtered_result, :results) do
      updated_results =
        Enum.zip(filtered_result[:results] || [], original_result.results)
        |> Enum.map(fn {filtered_record, original_record} ->
          do_add_read_metadata(filtered_record, original_record, request)
        end)

      Map.put(filtered_result, :results, updated_results)
    else
      do_add_read_metadata(filtered_result, original_result, request)
    end
  end

  defp add_read_metadata(filtered_result, _original_result, _request), do: filtered_result

  defp do_add_read_metadata(filtered_record, original_record, request)
       when is_map(filtered_record) do
    metadata_map = Map.get(original_record, :__metadata__, %{})
    Map.merge(filtered_record, format_metadata(metadata_map, request))
  end

  defp do_add_read_metadata(filtered_record, _original_record, _request), do: filtered_record

  defp add_mutation_metadata(filtered_result, original_result, request) do
    metadata_map = Map.get(original_result, :__metadata__, %{})
    %{data: filtered_result, metadata: format_metadata(metadata_map, request)}
  end

  # Extracts the configured metadata fields and formats each value using the
  # metadata field's declared Ash type. This routes through the same
  # type-driven dispatch as attribute/calculation values: typed maps get their
  # nested keys camelized, unconstrained `:map` / `{:array, :map}` metadata
  # passes through unchanged (so caller-provided keys like `_id` survive).
  # Each field is keyed by its client name, a binary key that goes out as-is:
  # read metadata merged into a record never takes the key of a field it
  # shares an internal name with.
  defp format_metadata(metadata_map, %Request{} = request) do
    metadata_defs = request.action.metadata || []

    client_names =
      request.entrypoint
      |> client_metadata_names(request.runtime)
      |> Map.new(fn {client, field} -> {field, client} end)

    Enum.reduce(request.show_metadata, %{}, fn metadata_field, acc ->
      value = Map.get(metadata_map, metadata_field)
      type = Enum.find_value(metadata_defs, &(&1.name == metadata_field && &1.type))
      formatted_value = ValueFormatter.format(value, type, [], :output, request.runtime)
      Map.put(acc, Map.fetch!(client_names, metadata_field), formatted_value)
    end)
  end
end
