# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.Decorator do
  @moduledoc """
  Writes `custom.ash_rpc` onto an `%Ash.Info.Manifest{}` using an
  `AshRpc.MappingSource`:

    * manifest — mapping source, formatters, wire `entrypoints`, `lookups`
    * exposed resources (domain and embedded) — client names, argument
      overrides, bulk-authorization strategy; many-cardinality relationships
      to exposed destinations get pagination capabilities
    * mapped types — field-name overrides
    * every entrypoint action — expected input keys, input field types,
      return classification

  Pure: manifest in, manifest out. Raises `AshRpc.Manifest.NameCollisionError`
  on client-name collisions and `ArgumentError` when a formatter misbehaves.
  """

  alias Ash.Info.Manifest
  alias AshRpc.{FieldFormatter, Introspection, Manifest.NameCollisionError}

  @spec decorate(Manifest.t(), module(), keyword()) :: Manifest.t()
  def decorate(%Manifest{} = manifest, mapping_source, opts \\ []) when is_atom(mapping_source) do
    input_formatter = Keyword.get_lazy(opts, :input_formatter, &mapping_source.input_formatter/0)

    output_formatter =
      Keyword.get_lazy(opts, :output_formatter, &mapping_source.output_formatter/0)

    ctx = %{
      source: mapping_source,
      formatter: output_formatter,
      exposed: exposed_modules(manifest, mapping_source),
      actions_by_resource: Enum.group_by(manifest.entrypoints, & &1.resource, & &1.action.name)
    }

    resources = Enum.map(manifest.resources, &decorate_resource(&1, ctx))
    types = Enum.map(manifest.types, &decorate_type(&1, ctx))
    staged = %Manifest{manifest | resources: resources, types: types}

    resource_lookup = AshRpc.Manifest.build_resource_lookup(staged)
    type_lookup = Manifest.type_lookup(staged)

    entrypoints =
      Enum.map(manifest.entrypoints, &decorate_entrypoint(&1, resource_lookup, type_lookup, ctx))

    payload = %{
      mapping_source: mapping_source,
      input_formatter: input_formatter,
      output_formatter: output_formatter,
      entrypoints: wire_entrypoints(entrypoints, mapping_source)
    }

    %Manifest{
      staged
      | entrypoints: entrypoints,
        custom: Map.put(manifest.custom, :ash_rpc, payload)
    }
    |> AshRpc.Manifest.put_lookups()
  end

  # ── exposure ──────────────────────────────────────────────────────

  defp exposed_modules(manifest, source) do
    embedded = for %Manifest.Type{kind: :embedded_resource, module: m} <- manifest.types, do: m

    (Enum.map(manifest.resources, & &1.module) ++ embedded)
    |> Enum.filter(&(is_atom(&1) and source.exposed_resource?(&1)))
    |> MapSet.new()
  end

  # ── resources ─────────────────────────────────────────────────────

  defp decorate_resource(%Manifest.Resource{module: module} = resource, ctx) do
    if MapSet.member?(ctx.exposed, module) do
      overrides = module |> ctx.source.field_names() |> Map.new()
      field_names = full_field_names(resource, overrides, ctx.formatter)
      check_collisions!(field_names, "resource #{inspect(module)}")
      argument_overrides = argument_overrides(module, ctx)

      payload = %{
        field_names: field_names,
        field_name_overrides: overrides,
        reverse_field_name_overrides: reverse_map(overrides),
        argument_name_overrides: argument_overrides,
        reverse_argument_name_overrides:
          Map.new(argument_overrides, fn {a, m} -> {a, reverse_map(m)} end),
        authorize_bulk_strategy: authorize_bulk_strategy(module)
      }

      %Manifest.Resource{
        resource
        | custom: Map.put(resource.custom, :ash_rpc, payload),
          relationships: decorate_relationships(resource, ctx)
      }
    else
      resource
    end
  end

  defp full_field_names(%Manifest.Resource{module: module} = resource, overrides, formatter) do
    (Map.keys(resource.fields) ++ Map.keys(resource.relationships))
    |> Enum.uniq()
    |> Map.new(fn field ->
      {field,
       Map.get(overrides, field) || client_name!(field, formatter, "resource #{inspect(module)}")}
    end)
  end

  defp argument_overrides(module, ctx) do
    ctx.actions_by_resource
    |> Map.get(module, [])
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn action, acc ->
      case module |> ctx.source.argument_names(action) |> Map.new() do
        empty when map_size(empty) == 0 -> acc
        mapping -> Map.put(acc, action, mapping)
      end
    end)
  end

  # The data-layer capability is fixed at compile time; precomputing it
  # replaces a per-request Ash.DataLayer.data_layer_can?/2 call.
  defp authorize_bulk_strategy(module) do
    if Ash.DataLayer.data_layer_can?(module, :expr_error), do: :error, else: :filter
  end

  # Derived from the relationship's configured read_action, falling back to
  # the destination's primary read. Decoration is the only moment that reads
  # Ash.Resource.Info; the runtime never does.
  defp decorate_relationships(%Manifest.Resource{module: module, relationships: rels}, ctx) do
    Map.new(rels, fn
      {name, %Manifest.Relationship{cardinality: :many, destination: dest} = rel} ->
        if MapSet.member?(ctx.exposed, dest) do
          caps = relationship_query_capabilities(module, rel)
          {name, %Manifest.Relationship{rel | custom: Map.put(rel.custom, :ash_rpc, caps)}}
        else
          {name, rel}
        end

      other ->
        other
    end)
  end

  defp relationship_query_capabilities(source_module, %Manifest.Relationship{
         name: name,
         destination: dest
       }) do
    ash_rel = Ash.Resource.Info.relationship(source_module, name)

    read_action_name =
      (ash_rel && Map.get(ash_rel, :read_action)) ||
        case Ash.Resource.Info.primary_action(dest, :read) do
          nil -> nil
          action -> action.name
        end

    pagination =
      case read_action_name && Ash.Resource.Info.action(dest, read_action_name) do
        %{pagination: %{offset?: true, keyset?: true}} -> :mixed
        %{pagination: %{offset?: true}} -> :offset
        %{pagination: %{keyset?: true}} -> :keyset
        _ -> :none
      end

    %{pagination: pagination, read_action: read_action_name}
  end

  # ── types ─────────────────────────────────────────────────────────

  defp decorate_type(
         %Manifest.Type{kind: :embedded_resource, resource: %Manifest.Resource{} = r} = type,
         ctx
       ) do
    %Manifest.Type{type | resource: decorate_resource(r, ctx)}
  end

  defp decorate_type(%Manifest.Type{} = type, ctx) do
    module = Manifest.Type.effective_module(type)

    case not is_nil(module) and Code.ensure_loaded?(module) and
           ctx.source.type_field_names(module) do
      mapping when is_map(mapping) ->
        overrides = Map.new(mapping)

        payload = %{
          field_name_overrides: overrides,
          reverse_field_name_overrides: reverse_map(overrides)
        }

        %Manifest.Type{type | custom: Map.put(type.custom, :ash_rpc, payload)}

      _ ->
        type
    end
  end

  # ── entrypoints / actions ────────────────────────────────────────

  defp decorate_entrypoint(%Manifest.Entrypoint{} = e, resource_lookup, type_lookup, ctx) do
    %Manifest.Entrypoint{
      e
      | action: decorate_action(e.action, e.resource, resource_lookup, type_lookup, ctx)
    }
  end

  defp decorate_action(%Manifest.Action{} = action, resource, resource_lookup, type_lookup, ctx) do
    resource_struct = Map.get(resource_lookup, resource)

    expected =
      Map.new(action.inputs, fn input ->
        {Introspection.format_input_name(resource_struct, action.name, input.name, ctx.formatter),
         input.name}
      end)

    if map_size(expected) != length(action.inputs) do
      raise NameCollisionError,
        message:
          collision_message(
            action,
            resource_struct,
            ctx.formatter,
            "action #{inspect(action.name)} on #{inspect(resource)}"
          )
    end

    payload = %{
      expected_input_keys: expected,
      input_field_types:
        Map.new(action.inputs, fn
          %{type: %Manifest.Type{} = t} = input -> {input.name, t}
          input -> {input.name, nil}
        end),
      return_classification: Introspection.compute_return_classification(action, type_lookup)
    }

    %Manifest.Action{action | custom: Map.put(action.custom, :ash_rpc, payload)}
  end

  defp decorate_action(action, _resource, _rl, _tl, _ctx), do: action

  defp collision_message(action, resource_struct, formatter, where) do
    action.inputs
    |> Enum.group_by(
      &Introspection.format_input_name(resource_struct, action.name, &1.name, formatter),
      & &1.name
    )
    |> Enum.filter(fn {_client, names} -> length(names) > 1 end)
    |> Enum.map_join("; ", fn {client, names} ->
      "#{Enum.map_join(names, " and ", &inspect/1)} both map to #{inspect(client)}"
    end)
    |> then(&"Client name collision in #{where}: #{&1}")
  end

  defp wire_entrypoints(entrypoints, source) do
    Enum.reduce(entrypoints, %{}, fn entrypoint, acc ->
      case source.entrypoint(entrypoint) do
        nil ->
          acc

        %AshRpc.Entrypoint{name: name} = e ->
          if Map.has_key?(acc, name) do
            raise ArgumentError,
                  "duplicate wire entrypoint name #{inspect(name)} from #{inspect(source)}"
          end

          Map.put(acc, name, e)
      end
    end)
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp client_name!(field, formatter, where) do
    case FieldFormatter.format_field_name(field, formatter) do
      name when is_binary(name) ->
        name

      other ->
        raise ArgumentError,
              "formatter #{inspect(formatter)} returned #{inspect(other)} for field #{inspect(field)} " <>
                "on #{where}; formatters must return a string"
    end
  rescue
    e in ArgumentError ->
      reraise e, __STACKTRACE__

    e ->
      reraise ArgumentError,
              [
                message:
                  "formatter #{inspect(formatter)} raised while formatting field #{inspect(field)} on #{where}: " <>
                    Exception.message(e)
              ],
              __STACKTRACE__
  end

  defp check_collisions!(field_names, where) do
    field_names
    |> Enum.group_by(fn {_field, client} -> client end, fn {field, _} -> field end)
    |> Enum.filter(fn {_client, fields} -> length(fields) > 1 end)
    |> case do
      [] ->
        :ok

      clashes ->
        details =
          Enum.map_join(clashes, "; ", fn {client, fields} ->
            "#{fields |> Enum.sort() |> Enum.map_join(" and ", &inspect/1)} both map to #{inspect(client)}"
          end)

        raise NameCollisionError, message: "Client name collision in #{where}: #{details}"
    end
  end

  defp reverse_map(map), do: Map.new(map, fn {k, v} -> {v, k} end)
end
