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

  defp format_data(data, resource, action_name_or_action, runtime) do
    case data do
      map when is_map(map) and not is_struct(map) ->
        format_map(map, resource, action_name_or_action, runtime)

      list when is_list(list) ->
        Enum.map(list, fn item ->
          format_data(item, resource, action_name_or_action, runtime)
        end)

      other ->
        other
    end
  end

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

  # Resolve the field type to %Ash.Info.Manifest.Type{} and handle struct resources specially
  defp format_value(
         value,
         %Ash.Info.Manifest.Type{kind: kind} = type_info,
         runtime
       )
       when kind in [:struct, :map] do
    inst = type_info.instance_of || type_info.module

    if inst && Introspection.ash_resource?(inst) && is_map(value) && not is_struct(value) do
      formatted_data =
        ValueFormatter.format(value, type_info, [], :input, runtime)

      cast_map_to_struct(formatted_data, inst)
    else
      ValueFormatter.format(value, type_info, [], :input, runtime)
    end
  end

  defp format_value(
         value,
         %Ash.Info.Manifest.Type{kind: :resource} = type_info,
         runtime
       ) do
    inst = type_info.resource_module || type_info.module

    if inst && is_map(value) && not is_struct(value) do
      formatted_data =
        ValueFormatter.format(value, type_info, [], :input, runtime)

      cast_map_to_struct(formatted_data, inst)
    else
      ValueFormatter.format(value, type_info, [], :input, runtime)
    end
  end

  # Embedded resources: only format field names, don't cast to struct.
  # Ash handles embedded resource input casting internally.
  defp format_value(
         value,
         %Ash.Info.Manifest.Type{kind: :embedded_resource} = type_info,
         runtime
       ) do
    ValueFormatter.format(value, type_info, [], :input, runtime)
  end

  defp format_value(
         value,
         %Ash.Info.Manifest.Type{kind: :array} = type_info,
         runtime
       ) do
    item_type = type_info.item_type

    if item_type &&
         match?(%Ash.Info.Manifest.Type{kind: k} when k in [:struct, :resource], item_type) do
      # Non-embedded struct/resource items need struct casting
      inst = item_type.instance_of || item_type.resource_module || item_type.module

      if inst && Introspection.ash_resource?(inst) && is_list(value) do
        Enum.map(value, fn item ->
          if is_map(item) && not is_struct(item) do
            formatted_item =
              ValueFormatter.format(item, item_type, [], :input, runtime)

            cast_map_to_struct(formatted_item, inst)
          else
            item
          end
        end)
      else
        ValueFormatter.format(value, type_info, [], :input, runtime)
      end
    else
      # Embedded resources and everything else: just format, Ash handles casting
      ValueFormatter.format(value, type_info, [], :input, runtime)
    end
  end

  defp format_value(value, %Ash.Info.Manifest.Type{} = type_info, runtime) do
    ValueFormatter.format(value, type_info, [], :input, runtime)
  end

  # Fallback for nil type
  defp format_value(value, nil, _runtime), do: value

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
