# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.InputFormatter do
  @moduledoc """
  Formats input data from client format to internal format.

  Converts client-provided field names and values to the internal representation
  expected by Ash actions. Delegates to ValueFormatter for recursive type-aware
  formatting of nested values using `%Ash.Info.Manifest.Type{}` structs.
  """

  alias Ash.Info.Manifest.Type
  alias AshRpc.{Introspection, ValueFormatter}
  alias AshRpc.Manifest.Custom

  @doc """
  Formats input data from client format to internal format.
  """
  def format(data, resource, action_name_or_action, runtime) do
    {:ok, format_data(data, resource, action_name_or_action, runtime)}
  catch
    :throw, error ->
      {:error, error}
  end

  defp get_action(runtime, resource, action_name) when is_atom(action_name) do
    Introspection.get_action!(runtime, resource, action_name)
  end

  defp get_action(_runtime, _resource, %{} = action), do: action

  defp format_data(data, resource, action_name_or_action, runtime)
       when is_map(data) and not is_struct(data),
       do: format_map(data, resource, action_name_or_action, runtime)

  defp format_data(data, _resource, _action_name_or_action, _runtime), do: data

  defp format_map(map, resource, action_name_or_action, runtime) do
    action = get_action(runtime, resource, action_name_or_action)

    # Build the expected keys map once for this action
    expected_keys = expected_keys(action, resource, runtime)

    Enum.into(map, %{}, fn {key, value} ->
      case Map.get(expected_keys, key) do
        nil ->
          {key, value}

        internal_key ->
          field_type = get_input_field_type(action, internal_key)
          formatted_value = format_value(value, field_type, runtime)
          {internal_key, formatted_value}
      end
    end)
  end

  @doc """
  Returns the `%{client_name => internal_name}` map for an action's inputs.
  Reads the map precomputed onto the action's `custom.ash_rpc` when present and
  computes it from the runtime's output formatter otherwise.
  """
  def expected_keys(action, resource, runtime) do
    Custom.action_expected_input_keys(action) ||
      Map.new(action.inputs, fn input ->
        {Introspection.format_input_name(
           Map.get(runtime.resource_lookup, resource),
           action.name,
           input.name,
           runtime.output_formatter
         ), input.name}
      end)
  end

  defp format_value(value, nil, _runtime), do: value

  defp format_value(value, %Type{kind: :array, item_type: item_type} = type, runtime)
       when is_list(value) do
    case item_type && struct_cast_target(item_type) do
      nil -> ValueFormatter.format(value, type, [], :input, runtime)
      module -> Enum.map(value, &format_array_item(&1, item_type, module, runtime))
    end
  end

  defp format_value(value, %Type{} = type, runtime) do
    formatted = ValueFormatter.format(value, type, [], :input, runtime)

    case struct_cast_target(type) do
      nil -> formatted
      module when is_map(value) and not is_struct(value) -> cast_map_to_struct(formatted, module)
      _module -> formatted
    end
  end

  defp format_array_item(item, item_type, module, runtime)
       when is_map(item) and not is_struct(item) do
    item
    |> ValueFormatter.format(item_type, [], :input, runtime)
    |> cast_map_to_struct(module)
  end

  defp format_array_item(item, _item_type, _module, _runtime), do: item

  # Non-embedded struct/resource inputs bound to an Ash resource are cast to the
  # resource struct after key formatting; Ash casts everything else (embedded
  # resources included) itself. A `:map` type never has a resource as its
  # effective module, so it never casts.
  defp struct_cast_target(%Type{kind: kind} = type) when kind in [:struct, :map, :resource] do
    module = Type.effective_resource(type)
    if Introspection.ash_resource?(module), do: module
  end

  defp struct_cast_target(_type), do: nil

  defp cast_map_to_struct(map, struct_module) when is_map(map) and is_atom(struct_module) do
    with {:ok, casted} <-
           Ash.Type.cast_input(Ash.Type.Struct, map, instance_of: struct_module),
         {:ok, constrained} <-
           Ash.Type.apply_constraints(Ash.Type.Struct, casted, instance_of: struct_module) do
      constrained
    else
      {:error, error} -> throw(error)
      :error -> throw("is invalid")
    end
  end

  # Returns %Ash.Info.Manifest.Type{} for the field. Every input — declared
  # argument or accepted attribute — appears in `action.inputs` with a
  # pre-resolved type. Reads the precomputed `%{internal_name => %Type{}}` map
  # from the action decoration when present; otherwise scans `action.inputs`.
  defp get_input_field_type(action, field_key) do
    case Custom.action_input_field_types(action) do
      nil ->
        case Enum.find(action.inputs, &(&1.name == field_key)) do
          %{type: %Ash.Info.Manifest.Type{} = type} -> type
          _ -> nil
        end

      types ->
        Map.get(types, field_key)
    end
  end
end
