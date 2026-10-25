# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.CustomTypes do
  @moduledoc false
  # Decoration pass for custom `use Ash.Type` modules with declared fields.
  #
  # 1. Collect: every `kind: :unknown` node with a module, anywhere in the
  #    undecorated manifest (or in `extra_types`), is asked about once.
  # 2. Build: declared fields become a named `kind: :map` definition, marked
  #    `custom.ash_rpc.custom_type: true`.
  # 3. Fixpoint: a definition's fields are walked. Custom types are asked
  #    about, named types missing from the manifest are resolved and added,
  #    and resources must already be in the manifest.
  # 4. Stage: a `manifest.types` entry `kind: :unknown` for a declared module
  #    (a NewType over a custom type) is replaced in place, an existing
  #    definition (a redecorate) is kept; the rest is appended.
  #
  # The decorator then rewrites every declared use to a `:type_ref`.

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Generator.TypeResolver

  @type fields_fun :: (module() -> [AshRpc.MappingSource.field_spec()] | nil)

  @spec declare(Manifest.t(), fields_fun(), [Manifest.Type.t()]) ::
          {[Manifest.Type.t()], MapSet.t(module())}
  def declare(%Manifest{} = manifest, fields_fun, extra_types) when is_function(fields_fun, 1) do
    state = %{
      fields_fun: fields_fun,
      # module => definition, or nil when the module declares nothing
      asked: %{},
      # named types the fixpoint resolved, module => definition
      resolved: %{},
      # discovery order of new entries
      order: [],
      types: MapSet.new(manifest.types, & &1.module),
      resources: MapSet.new(manifest.resources, & &1.module)
    }

    state =
      manifest
      |> manifest_trees()
      |> Kernel.++(extra_types)
      |> Enum.reduce(state, &collect(&1, &2))

    declared = for {m, %Manifest.Type{}} <- state.asked, into: MapSet.new(), do: m
    {stage(manifest.types, state, declared), declared}
  end

  # ── collect ───────────────────────────────────────────────────────

  defp manifest_trees(%Manifest{} = manifest) do
    resource_trees = Enum.flat_map(manifest.resources, &resource_trees/1)

    entrypoint_trees =
      Enum.flat_map(manifest.entrypoints, fn %Manifest.Entrypoint{action: action} ->
        entry_types(action.inputs) ++ [action.returns] ++ entry_types(action.metadata)
      end)

    resource_trees ++ manifest.types ++ entrypoint_trees
  end

  defp resource_trees(%Manifest.Resource{fields: fields}) do
    Enum.flat_map(fields, fn {_name, field} -> [field.type | entry_types(field.arguments)] end)
  end

  defp entry_types(entries) when is_list(entries), do: Enum.map(entries, &Map.get(&1, :type))
  defp entry_types(_), do: []

  defp collect(%Manifest.Type{kind: :unknown, module: m}, state)
       when is_atom(m) and not is_nil(m),
       do: ask(m, state)

  defp collect(
         %Manifest.Type{kind: :embedded_resource, resource: %Manifest.Resource{} = r},
         state
       ),
       do: r |> resource_trees() |> Enum.reduce(state, &collect/2)

  defp collect(%Manifest.Type{} = type, state),
    do: type |> children() |> Enum.reduce(state, &collect/2)

  defp collect(_other, state), do: state

  defp children(%Manifest.Type{} = type) do
    entries = List.wrap(type.fields) ++ List.wrap(type.element_types) ++ List.wrap(type.members)
    [type.item_type | entry_types(entries)]
  end

  # ── build ─────────────────────────────────────────────────────────

  defp ask(module, state) do
    if Map.has_key?(state.asked, module) do
      state
    else
      case state.fields_fun.(module) do
        nil ->
          %{state | asked: Map.put(state.asked, module, nil)}

        specs ->
          definition = definition(module, specs)

          state = %{
            state
            | asked: Map.put(state.asked, module, definition),
              order: [module | state.order]
          }

          Enum.reduce(definition.fields, state, fn %{name: name, type: type}, state ->
            fixpoint(type, {module, name}, state)
          end)
      end
    end
  end

  defp definition(module, specs) do
    fields = specs |> validate_specs!(module) |> Enum.map(&field/1)

    client_names =
      for {name, opts} <- specs, client = opts[:client_name], into: %{}, do: {name, client}

    marker =
      if client_names == %{},
        do: %{custom_type: true},
        else: %{
          custom_type: true,
          field_name_overrides: client_names,
          reverse_field_name_overrides: Map.new(client_names, fn {k, v} -> {v, k} end)
        }

    %Manifest.Type{
      kind: :map,
      name: type_name(module),
      module: module,
      constraints: default_constraints(module),
      instance_of: nil,
      fields: fields,
      custom: %{ash_rpc: marker}
    }
  end

  defp validate_specs!([_ | _] = specs, module) do
    Enum.each(specs, fn
      {name, opts} when is_atom(name) and is_list(opts) ->
        unless Keyword.keyword?(opts) and Keyword.has_key?(opts, :type) do
          raise ArgumentError, bad_spec(module, {name, opts}, "options need :type")
        end

        client = opts[:client_name]

        unless is_nil(client) or is_binary(client) do
          raise ArgumentError,
                "custom type #{inspect(module)}, field #{inspect(name)}: client_name must be " <>
                  "a string, got: #{inspect(client)}"
        end

      entry ->
        raise ArgumentError,
              bad_spec(
                module,
                entry,
                "expected {name, opts} with an atom name and a keyword list"
              )
    end)

    names = Enum.map(specs, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] ->
        specs

      [name | _] ->
        raise ArgumentError,
              "custom type #{inspect(module)} declares the field #{inspect(name)} more than once"
    end
  end

  defp validate_specs!(specs, module) do
    raise ArgumentError,
          "custom type #{inspect(module)} declares no fields: expected a non-empty list of " <>
            "{name, opts} field specs or nil, got: #{inspect(specs)}"
  end

  defp bad_spec(module, entry, why),
    do: "custom type #{inspect(module)} has an invalid field spec #{inspect(entry)}: #{why}"

  # As Ash resolves a typed map's `fields` constraint.
  defp field({name, opts}) do
    %{
      name: name,
      type: TypeResolver.resolve(opts[:type], opts[:constraints] || []),
      allow_nil?: Keyword.get(opts, :allow_nil?, true),
      description: opts[:description]
    }
  end

  defp default_constraints(module) do
    case Ash.Type.init(module, []) do
      {:ok, constraints} -> constraints
      _ -> []
    end
  end

  @doc false
  @spec type_name(module()) :: String.t()
  def type_name(module), do: module |> Module.split() |> List.last()

  # ── fixpoint ──────────────────────────────────────────────────────

  defp fixpoint(%Manifest.Type{kind: :unknown, module: m}, _where, state)
       when is_atom(m) and not is_nil(m),
       do: ask(m, state)

  defp fixpoint(%Manifest.Type{kind: :type_ref, module: m}, where, state) do
    if known_type?(m, state) do
      state
    else
      case TypeResolver.resolve_definition(m) do
        # A NewType over a custom type: asked about like any custom type. An
        # undeclared one keeps its `:unknown` definition.
        %Manifest.Type{kind: :unknown} = resolved ->
          state = ask(m, state)

          if state.asked[m],
            do: state,
            else: add_resolved(m, resolved, state)

        resolved ->
          resolved
          |> children()
          |> Enum.reduce(add_resolved(m, resolved, state), &fixpoint(&1, where, &2))
      end
    end
  end

  defp fixpoint(%Manifest.Type{kind: kind} = type, {module, field}, state)
       when kind in [:resource, :embedded_resource] do
    resource = Manifest.Type.effective_resource(type)

    if MapSet.member?(state.resources, resource) or MapSet.member?(state.types, resource) do
      state
    else
      raise ArgumentError,
            "custom type #{inspect(module)}, field #{inspect(field)}: #{inspect(resource)} " <>
              "is not in the manifest"
    end
  end

  defp fixpoint(%Manifest.Type{} = type, where, state),
    do: type |> children() |> Enum.reduce(state, &fixpoint(&1, where, &2))

  defp fixpoint(_other, _where, state), do: state

  defp known_type?(module, state) do
    MapSet.member?(state.types, module) or Map.has_key?(state.resolved, module) or
      is_struct(state.asked[module], Manifest.Type)
  end

  defp add_resolved(module, resolved, state) do
    %{state | resolved: Map.put(state.resolved, module, resolved), order: [module | state.order]}
  end

  # ── stage ─────────────────────────────────────────────────────────

  defp stage(types, state, declared) do
    existing =
      Enum.map(types, fn
        %Manifest.Type{kind: :unknown, module: m} = entry ->
          if MapSet.member?(declared, m), do: state.asked[m], else: entry

        # Already declared (a redecorate): the definition stays as it is.
        %Manifest.Type{custom: %{ash_rpc: %{custom_type: true}}} = entry ->
          entry

        %Manifest.Type{kind: kind, module: m} = entry ->
          if MapSet.member?(declared, m) do
            raise ArgumentError,
                  "custom type #{inspect(m)} declares fields, but #{inspect(m)} already has " <>
                    "a manifest.types entry of kind #{inspect(kind)}"
          end

          entry
      end)

    staged = MapSet.new(types, & &1.module)

    appended =
      for m <- Enum.reverse(state.order), not MapSet.member?(staged, m) do
        state.asked[m] || Map.fetch!(state.resolved, m)
      end

    existing ++ appended
  end
end
