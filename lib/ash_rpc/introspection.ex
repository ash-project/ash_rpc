# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Introspection do
  @moduledoc "Runtime action and type helpers."

  @doc """
  Returns true if the action supports pagination.

  ## Examples

      iex> AshRpc.Introspection.action_supports_pagination?(%{type: :read, get?: false, pagination: %{offset?: true}})
      true

      iex> AshRpc.Introspection.action_supports_pagination?(%{type: :read, get?: true})
      false
  """
  def action_supports_pagination?(action) do
    action.type == :read and not action.get? and has_pagination_config?(action)
  end

  @doc """
  Returns true if the action supports offset-based pagination.
  """
  def action_supports_offset_pagination?(action) do
    case get_pagination_config(action) do
      nil -> false
      pagination_config -> Map.get(pagination_config, :offset?, false)
    end
  end

  @doc """
  Returns true if the action supports keyset-based pagination.
  """
  def action_supports_keyset_pagination?(action) do
    case get_pagination_config(action) do
      nil -> false
      pagination_config -> Map.get(pagination_config, :keyset?, false)
    end
  end

  @doc """
  Returns true if the action requires pagination.
  """
  def action_requires_pagination?(action) do
    case get_pagination_config(action) do
      nil -> false
      pagination_config -> Map.get(pagination_config, :required?, false)
    end
  end

  @doc """
  Returns true if the action supports countable pagination.
  """
  def action_supports_countable?(action) do
    case get_pagination_config(action) do
      nil ->
        false

      pagination_config ->
        # Ash.Info.Manifest.Pagination uses `:countable?`; raw Ash uses `:countable`
        Map.get(pagination_config, :countable?) || Map.get(pagination_config, :countable, false)
    end
  end

  @doc """
  Returns true if the action has a default limit configured.
  """
  def action_has_default_limit?(action) do
    case get_pagination_config(action) do
      nil -> false
      pagination_config -> Map.has_key?(pagination_config, :default_limit)
    end
  end

  defp has_pagination_config?(action) do
    case action do
      %{pagination: pagination} when is_map(pagination) -> true
      _ -> false
    end
  end

  defp get_pagination_config(action) do
    case action do
      %{pagination: pagination} when is_map(pagination) -> pagination
      _ -> nil
    end
  end

  @doc """
  Returns `true` if `input_name` refers to an accepted attribute on `resource`
  (i.e. present in the manifest resource's `fields` map) rather than a
  declared action argument. Used to decide whether to apply field-name mapping
  or argument-name mapping to an `Ash.Info.Manifest.Argument`.
  """
  def accepted_attribute?(resource, input_name, resource_lookup) do
    case Map.get(resource_lookup || %{}, resource) do
      %Ash.Info.Manifest.Resource{fields: fields} when is_map(fields) ->
        Map.has_key?(fields, input_name)

      _ ->
        false
    end
  end

  @doc """
  Checks if a generic action returns a field-selectable type, taking an
  explicit `type_lookup` so it can run during manifest decoration.

  Returns:
  - `{:ok, :resource, resource_module}` - Single resource
  - `{:ok, :array_of_resource, resource_module}` - Array of resources
  - `{:ok, :typed_map, fields}` - Typed map with constraints
  - `{:ok, :array_of_typed_map, fields}` - Array of typed maps
  - `{:ok, :typed_struct, {module, fields}}` - Type with field constraints (TypedStruct or similar)
  - `{:ok, :array_of_typed_struct, {module, fields}}` - Array of types with field constraints
  - `{:ok, :unconstrained_map, nil}` - Map without field constraints
  - `{:ok, :array_of_unconstrained_map, nil}` - Array of maps without field constraints
  - `{:error, :not_generic_action}` - Not a generic action
  - `{:error, reason}` - Other errors
  """
  def compute_return_classification(action, type_lookup) do
    if action.type != :action do
      {:error, :not_generic_action}
    else
      check_action_returns(action, type_lookup)
    end
  end

  defp check_action_returns(action, type_lookup) do
    {base_type, is_array} = unwrap_return_type(action, type_lookup)

    case classify_return_type(base_type, type_lookup) do
      {:resource, module} ->
        if is_array do
          {:ok, :array_of_resource, module}
        else
          {:ok, :resource, module}
        end

      {:typed_map, fields} ->
        if is_array do
          {:ok, :array_of_typed_map, fields}
        else
          {:ok, :typed_map, fields}
        end

      {:typed_struct, {module, fields}} ->
        if is_array do
          {:ok, :array_of_typed_struct, {module, fields}}
        else
          {:ok, :typed_struct, {module, fields}}
        end

      :unconstrained_map ->
        if is_array do
          {:ok, :array_of_unconstrained_map, nil}
        else
          {:ok, :unconstrained_map, nil}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unwrap_return_type(action, type_lookup) do
    case action.returns do
      %Ash.Info.Manifest.Type{kind: :array, item_type: item_type} ->
        {item_type, true}

      %Ash.Info.Manifest.Type{kind: :type_ref, module: module} ->
        {Ash.Info.Manifest.get_type!(type_lookup, module), false}

      type ->
        {type, false}
    end
  end

  # Classifies a return type into a category for field selectability
  @spec classify_return_type(Ash.Info.Manifest.Type.t() | nil, map()) ::
          {:resource, module()}
          | {:typed_map, keyword()}
          | {:typed_struct, {module(), keyword()}}
          | :unconstrained_map
          | {:error, atom()}
  defp classify_return_type(%Ash.Info.Manifest.Type{kind: :type_ref, module: module}, type_lookup) do
    type_lookup
    |> Ash.Info.Manifest.get_type!(module)
    |> classify_return_type(type_lookup)
  end

  defp classify_return_type(
         %Ash.Info.Manifest.Type{kind: kind, resource_module: mod},
         _type_lookup
       )
       when kind in [:resource, :embedded_resource] and not is_nil(mod) do
    {:resource, mod}
  end

  defp classify_return_type(
         %Ash.Info.Manifest.Type{kind: :struct, fields: fields, instance_of: inst},
         _type_lookup
       )
       when is_list(fields) and fields != [] and not is_nil(inst) do
    {:typed_struct, {inst, fields}}
  end

  defp classify_return_type(
         %Ash.Info.Manifest.Type{kind: kind} = type_info,
         _type_lookup
       )
       when kind in [:map, :keyword, :tuple] do
    fields = Ash.Info.Manifest.Type.get_fields(type_info)

    if fields != [] do
      {:typed_map, fields}
    else
      :unconstrained_map
    end
  end

  defp classify_return_type(_type, _type_lookup), do: {:error, :not_field_selectable_type}

  @doc """
  Gets the list of metadata fields that should be exposed for an RPC action.

  ## Parameters

    * `rpc_action` - The RPC action configuration
    * `ash_action` - The underlying Ash action

  ## Returns

  A list of metadata field names (atoms) that should be exposed.

  ## Examples

      # No metadata override - expose all metadata fields
      iex> AshRpc.Introspection.get_exposed_metadata_fields(%{}, %{metadata: [%{name: :total_count}]})
      [:total_count]

      # Empty list - expose no metadata fields
      iex> AshRpc.Introspection.get_exposed_metadata_fields(%{show_metadata: []}, %{metadata: [%{name: :total_count}]})
      []

      # Specific fields - expose only listed fields
      iex> AshRpc.Introspection.get_exposed_metadata_fields(%{show_metadata: [:total_count]}, %{metadata: [...]})
      [:total_count]
  """
  def get_exposed_metadata_fields(rpc_action, ash_action) do
    show_metadata = Map.get(rpc_action, :show_metadata, nil)

    case show_metadata do
      nil -> Enum.map(Map.get(ash_action, :metadata, []), & &1.name)
      false -> []
      [] -> []
      field_list when is_list(field_list) -> field_list
    end
  end

  @doc """
  Checks if metadata is enabled for an action based on exposed fields.

  ## Parameters

    * `exposed_fields` - List of metadata fields that are exposed

  ## Returns

  Boolean indicating if metadata is enabled (has at least one exposed field).
  """
  def metadata_enabled?(exposed_fields) do
    not Enum.empty?(exposed_fields)
  end

  @doc "Returns true if the module is an Ash resource."
  @spec ash_resource?(atom()) :: boolean()
  def ash_resource?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) == true and Ash.Resource.Info.resource?(module)
  end

  def ash_resource?(_), do: false

  @doc """
  Checks if a module is an embedded Ash resource.

  ## Examples

      iex> AshRpc.Introspection.embedded_resource?(MyApp.Accounts.Address)
      true

      iex> AshRpc.Introspection.embedded_resource?(MyApp.Accounts.User)
      false
  """
  def embedded_resource?(module) when is_atom(module) do
    Ash.Resource.Info.resource?(module) and Ash.Resource.Info.embedded?(module)
  end

  def embedded_resource?(_), do: false

  @doc """
  Checks if constraints specify an instance_of that is an Ash resource.

  ## Examples

      iex> AshRpc.Introspection.resource_instance_of?([instance_of: MyApp.Todo])
      true

      iex> AshRpc.Introspection.resource_instance_of?([])
      false
  """
  def resource_instance_of?(constraints) when is_list(constraints) do
    case Keyword.get(constraints, :instance_of) do
      nil -> false
      module -> is_atom(module) && Ash.Resource.Info.resource?(module)
    end
  end

  def resource_instance_of?(_), do: false

  @doc """
  Looks up an action in the runtime's action lookup and raises on miss.

  Use at runtime sites that have already validated action existence upstream,
  so a miss indicates an internal consistency error rather than user input.
  """
  def get_action!(%{action_lookup: lookup}, resource, action_name) do
    case Map.get(lookup, {resource, action_name}) do
      %Ash.Info.Manifest.Action{} = action -> action
      nil -> raise "action #{inspect(action_name)} not found on #{inspect(resource)} in manifest"
    end
  end

  @doc "Return classification, read from decoration when present (see `compute_return_classification/2`)."
  def return_classification(%Ash.Info.Manifest.Action{} = action, type_lookup) do
    AshRpc.Manifest.Custom.action_return_classification(action) ||
      compute_return_classification(action, type_lookup)
  end

  @doc """
  Resolves a named type's full definition: from the type lookup first, then
  directly from the module. The fallback serves callers that format values
  of types from outside the manifest; types reached through an entrypoint
  are always in the type lookup.
  """
  def named_type_definition(type_lookup, module) do
    Ash.Info.Manifest.get_type(type_lookup, module) ||
      Ash.Info.Manifest.Generator.TypeResolver.resolve_definition(module)
  end

  @doc """
  Client-name overrides for a type module: decorated type first, then the
  mapping source (D4) for types the manifest doesn't carry.
  """
  def type_field_name_overrides(%{type_lookup: type_lookup, mapping_source: source}, module)
      when is_atom(module) and not is_nil(module) do
    case Ash.Info.Manifest.get_type(type_lookup, module) do
      %Ash.Info.Manifest.Type{} = type ->
        case AshRpc.Manifest.Custom.type_field_name_overrides_pair(type) do
          {fwd, _rev} -> fwd
          nil -> source_type_field_names(source, module)
        end

      nil ->
        source_type_field_names(source, module)
    end
  end

  def type_field_name_overrides(_runtime, _module), do: nil

  defp source_type_field_names(nil, _module), do: nil

  defp source_type_field_names(source, module) do
    case source.type_field_names(module) do
      nil -> nil
      map -> Map.new(map)
    end
  end

  @doc "True when `module` has client field-name overrides (see `type_field_name_overrides/2`)."
  @spec has_field_name_overrides?(AshRpc.Runtime.t(), module() | nil) :: boolean()
  def has_field_name_overrides?(_runtime, nil), do: false

  def has_field_name_overrides?(runtime, module),
    do: not is_nil(type_field_name_overrides(runtime, module))

  @doc """
  Classifies a manifest type for type-directed traversal (result extraction,
  value formatting, field selection). A `:type_ref` is resolved leniently via
  `named_type_definition/2`, so named types the manifest doesn't carry still
  classify.

    * `{:array, item_type}`
    * `{:resource, module}` — resources, embedded resources, and structs/maps
      whose effective module is an Ash resource
    * `{:union, type}`
    * `{:typed_struct, type}` — struct/map/tuple/keyword with field-name overrides
    * `{:fields, type}` — struct/map/tuple/keyword without overrides
    * `{:other, type}` — everything else (`type` is nil for an unresolvable ref)
  """
  @spec classify_type(Ash.Info.Manifest.Type.t() | nil, AshRpc.Runtime.t()) ::
          {:array | :union | :typed_struct | :fields | :other, Ash.Info.Manifest.Type.t() | nil}
          | {:resource, module()}
  def classify_type(%Ash.Info.Manifest.Type{kind: :type_ref, module: module}, runtime) do
    runtime.type_lookup
    |> named_type_definition(module)
    |> classify_type(runtime)
  end

  def classify_type(%Ash.Info.Manifest.Type{kind: :array, item_type: item_type}, _runtime),
    do: {:array, item_type}

  def classify_type(%Ash.Info.Manifest.Type{kind: kind} = type, _runtime)
      when kind in [:resource, :embedded_resource],
      do: {:resource, Ash.Info.Manifest.Type.effective_resource(type)}

  def classify_type(%Ash.Info.Manifest.Type{kind: :union} = type, _runtime), do: {:union, type}

  def classify_type(%Ash.Info.Manifest.Type{kind: kind} = type, runtime)
      when kind in [:struct, :map, :tuple, :keyword] do
    module = Ash.Info.Manifest.Type.effective_module(type)

    cond do
      kind in [:struct, :map] and ash_resource?(module) -> {:resource, module}
      has_field_name_overrides?(runtime, module) -> {:typed_struct, type}
      true -> {:fields, type}
    end
  end

  def classify_type(type, _runtime), do: {:other, type}

  @doc "Client name of an action input: accepted attribute → field naming, argument → overrides."
  def format_input_name(
        %Ash.Info.Manifest.Resource{} = resource,
        action_name,
        input_name,
        formatter
      ) do
    if Map.has_key?(resource.fields, input_name) do
      AshRpc.FieldFormatter.format_field_for_client(input_name, resource, formatter)
    else
      AshRpc.Manifest.Custom.argument_name_override(resource, action_name, input_name) ||
        AshRpc.FieldFormatter.format_field_name(input_name, formatter)
    end
  end

  def format_input_name(nil, _action_name, input_name, formatter),
    do: AshRpc.FieldFormatter.format_field_name(input_name, formatter)
end
