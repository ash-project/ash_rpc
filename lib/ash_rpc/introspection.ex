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
  - `{:ok, :typed_map, fields}` - Typed map with constraints, or a `:struct` with `fields` and no `instance_of`
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

  # Without `instance_of` there is no struct module behind the fields, so the
  # value is selected like a typed map (matching the field selector).
  defp classify_return_type(
         %Ash.Info.Manifest.Type{kind: :struct, fields: fields},
         _type_lookup
       )
       when is_list(fields) and fields != [] do
    {:typed_map, fields}
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
  Gets the list of metadata fields that should be exposed for an action.

  A mapping source can use it to compute `AshRpc.Entrypoint.exposed_metadata_fields`.

  ## Parameters

    * `config` - A map or struct with an optional `:show_metadata` key: `nil`
      (or absent) exposes every metadata field the action declares, `false` or
      `[]` exposes none, and a list exposes those fields
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
      iex> AshRpc.Introspection.get_exposed_metadata_fields(%{show_metadata: [:total_count]}, %{metadata: [%{name: :total_count}, %{name: :page_size}]})
      [:total_count]
  """
  def get_exposed_metadata_fields(config, ash_action) do
    show_metadata = Map.get(config, :show_metadata, nil)

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
  Checks if a module is an embedded Ash resource (`data_layer: :embedded`).
  Returns `false` for non-embedded resources and for modules that are not
  resources.

  ## Examples

      iex> AshRpc.Introspection.embedded_resource?(String)
      false
  """
  def embedded_resource?(module) when is_atom(module) do
    Ash.Resource.Info.resource?(module) and Ash.Resource.Info.embedded?(module)
  end

  def embedded_resource?(_), do: false

  @doc """
  Checks if constraints specify an instance_of that is an Ash resource.
  `[instance_of: MyApp.Todo]` is `true` when `MyApp.Todo` is a resource.

  ## Examples

      iex> AshRpc.Introspection.resource_instance_of?(instance_of: String)
      false

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

  @typedoc "A step on a path through a type tree: a field, member or argument name, or `[]` for array items."
  @type type_path_segment :: atom() | []

  @doc """
  True for a struct type the manifest has no field types for: `kind: :struct`
  with `fields: nil` and an `instance_of` that is `nil` or not an Ash
  resource. Such a value can't be selected, named or filtered.

  An explicit empty field list (`fields: []`) is typed only when `instance_of`
  is an Ash type (an empty TypedStruct) or an Ash resource. Without
  `instance_of`, or with any other module (a plain `defstruct`), it is untyped:
  a struct the action returns would reach the client with all its own fields.

  A `:struct` whose `instance_of` is an Ash type (a TypedStruct or a NewType)
  and has `fields: nil` counts too: `Ash.Type.Struct` doesn't take fields from
  `instance_of`, so the manifest has none. Using that module as the type is
  what carries its fields.

  Decoration-time only: it may load the `instance_of` module to ask whether
  it is an Ash type.

  ## Examples

      iex> AshRpc.Introspection.untyped_struct?(%Ash.Info.Manifest.Type{kind: :struct})
      true

      iex> AshRpc.Introspection.untyped_struct?(%Ash.Info.Manifest.Type{kind: :map})
      false
  """
  @spec untyped_struct?(Ash.Info.Manifest.Type.t() | nil) :: boolean()
  def untyped_struct?(%Ash.Info.Manifest.Type{kind: :struct, fields: nil, instance_of: inst}),
    do: not ash_resource?(inst)

  def untyped_struct?(%Ash.Info.Manifest.Type{kind: :struct, fields: [], instance_of: inst})
      when is_atom(inst),
      do: not ash_resource?(inst) and not ash_type_module?(inst)

  def untyped_struct?(_), do: false

  # `Ash.Type.ash_type?/1` doesn't load the module and raises and rescues for
  # a plain struct, so check the export after loading it.
  defp ash_type_module?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :ash_type?, 0) and
      module.ash_type?()
  end

  @doc """
  Walks a manifest type tree and returns `{path, type}` for the first untyped
  struct (`untyped_struct?/1`), or `nil` when there is none. `type` is the
  offending node as the manifest has it, so its `instance_of` (or `module`)
  names the struct.

  The walk follows array items (path segment `[]`), the `fields` of maps,
  structs and keywords, tuple `element_types`, union `members`, named types
  (`:type_ref`, resolved with `named_type_definition/2`), and resource and
  embedded-resource nodes. For a resource it walks the public fields the
  manifest carries (attributes, calculations and aggregates, each field's type
  and then its calculation arguments) in name order, then its relationships in
  name order. A relationship is followed only when its destination is exposed
  (`AshRpc.Manifest.Custom.exposed?/1`), because relationships to unexposed
  resources can't be selected. Resource nodes reached by type are walked
  whatever their exposure. Each named type and resource is visited once, so
  recursive types terminate.

  `lookups` is any map with `:resource_lookup` and `:type_lookup` (an
  `%AshRpc.Runtime{}` qualifies). They must come from a decorated manifest, so
  that relationship exposure is known. Only those lookups are read.
  """
  @spec find_untyped_struct(Ash.Info.Manifest.Type.t() | nil, %{
          required(:resource_lookup) => map(),
          required(:type_lookup) => map(),
          optional(atom()) => term()
        }) :: {[type_path_segment()], Ash.Info.Manifest.Type.t()} | nil
  def find_untyped_struct(type, %{resource_lookup: _, type_lookup: _} = lookups) do
    case walk_untyped(type, lookups, MapSet.new()) do
      {:found, path, found} -> {path, found}
      {:ok, _visited} -> nil
    end
  end

  @doc """
  Runs `find_untyped_struct/2` over `{root, type, tag}` roots in order and
  returns `{[root | path], type, tag}` for the first that reaches an untyped
  struct, or `nil`. `root` labels the place (such as `"returns"` or
  `"argument :session"`); `tag` is carried through for the caller, such as
  the verb for `AshRpc.Manifest.UntypedStructError`.
  """
  @spec find_untyped_root([{term(), Ash.Info.Manifest.Type.t() | nil, tag}], map()) ::
          {list(), Ash.Info.Manifest.Type.t(), tag} | nil
        when tag: term()
  def find_untyped_root(roots, lookups) do
    Enum.find_value(roots, fn {root, type, tag} ->
      case find_untyped_struct(type, lookups) do
        nil -> nil
        {path, found} -> {[root | path], found, tag}
      end
    end)
  end

  defp walk_untyped(nil, _lookups, visited), do: {:ok, visited}

  defp walk_untyped(%Ash.Info.Manifest.Type{} = type, lookups, visited) do
    if untyped_struct?(type) do
      {:found, [], type}
    else
      walk_untyped_children(type, lookups, visited)
    end
  end

  defp walk_untyped(_other, _lookups, visited), do: {:ok, visited}

  defp walk_untyped_children(
         %Ash.Info.Manifest.Type{kind: :array, item_type: item},
         lookups,
         visited
       ),
       do: walk_untyped_segments([{[], item}], lookups, visited)

  defp walk_untyped_children(
         %Ash.Info.Manifest.Type{kind: :type_ref, module: module},
         lookups,
         visited
       ) do
    if MapSet.member?(visited, {:type, module}) do
      {:ok, visited}
    else
      lookups.type_lookup
      |> named_type_definition(module)
      |> walk_untyped(lookups, MapSet.put(visited, {:type, module}))
    end
  end

  defp walk_untyped_children(%Ash.Info.Manifest.Type{kind: kind} = type, lookups, visited)
       when kind in [:resource, :embedded_resource] do
    module = Ash.Info.Manifest.Type.effective_resource(type)
    resource = Map.get(lookups.resource_lookup, module) || type.resource
    walk_untyped_resource(module, resource, lookups, visited)
  end

  defp walk_untyped_children(%Ash.Info.Manifest.Type{} = type, lookups, visited) do
    (List.wrap(type.fields) ++ List.wrap(type.element_types) ++ List.wrap(type.members))
    |> Enum.map(fn %{name: name, type: child} -> {name, child} end)
    |> walk_untyped_segments(lookups, visited)
  end

  defp walk_untyped_resource(_module, nil, _lookups, visited), do: {:ok, visited}

  defp walk_untyped_resource(module, %Ash.Info.Manifest.Resource{} = resource, lookups, visited) do
    if MapSet.member?(visited, {:resource, module}) do
      {:ok, visited}
    else
      visited = MapSet.put(visited, {:resource, module})

      field_steps =
        resource.fields
        |> Enum.sort_by(fn {name, _field} -> name end)
        |> Enum.flat_map(fn {name, field} -> field_untyped_steps(name, field) end)

      relationship_steps =
        resource.relationships
        |> Enum.sort_by(fn {name, _rel} -> name end)
        |> Enum.filter(fn {_name, rel} -> exposed_destination?(rel, lookups) end)
        |> Enum.map(fn {name, rel} ->
          {name,
           %Ash.Info.Manifest.Type{
             kind: :resource,
             module: rel.destination,
             resource_module: rel.destination
           }}
        end)

      walk_untyped_segments(field_steps ++ relationship_steps, lookups, visited)
    end
  end

  defp field_untyped_steps(name, field) do
    arguments =
      field
      |> Map.get(:arguments)
      |> List.wrap()
      |> Enum.map(fn %{name: arg_name, type: arg_type} -> {[name, arg_name], arg_type} end)

    [{name, field.type} | arguments]
  end

  defp exposed_destination?(%{destination: destination}, lookups) do
    lookups.resource_lookup
    |> Map.get(destination)
    |> AshRpc.Manifest.Custom.exposed?()
  end

  # Each step is `{segment, type}`; a segment that is a list of names is
  # spliced into the path (a calculation argument's `[field, argument]`).
  defp walk_untyped_segments(steps, lookups, visited) do
    Enum.reduce_while(steps, {:ok, visited}, fn {segment, child}, {:ok, visited} ->
      case walk_untyped(child, lookups, visited) do
        {:found, path, found} -> {:halt, {:found, path_prefix(segment) ++ path, found}}
        {:ok, visited} -> {:cont, {:ok, visited}}
      end
    end)
  end

  defp path_prefix([]), do: [[]]
  defp path_prefix(names) when is_list(names), do: names
  defp path_prefix(name), do: [name]

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
  True when `type` declares no shape, so its values are untyped data: an
  unconstrained `:map` (no `fields`, or an empty list), `Ash.Type.Term`, an
  array of either, or a named type defined as an unconstrained map. Untyped
  data is sent exactly as the action produced it. Other `:term`-kind types
  (`Ash.Type.Vector`, a NewType over `:term`, …) are typed: the manifest gives
  their module, not their subtype.
  """
  @spec untyped_data_type?(Ash.Info.Manifest.Type.t() | nil, map()) :: boolean()
  def untyped_data_type?(%Ash.Info.Manifest.Type{kind: :array, item_type: item}, type_lookup),
    do: untyped_data_type?(item, type_lookup)

  def untyped_data_type?(%Ash.Info.Manifest.Type{kind: :type_ref, module: module}, type_lookup),
    do: untyped_data_type?(named_type_definition(type_lookup, module), type_lookup)

  def untyped_data_type?(%Ash.Info.Manifest.Type{kind: :map} = type, _type_lookup),
    do: Ash.Info.Manifest.Type.get_fields(type) == []

  def untyped_data_type?(%Ash.Info.Manifest.Type{kind: :term, module: Ash.Type.Term}, _),
    do: true

  def untyped_data_type?(_type, _type_lookup), do: false

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
