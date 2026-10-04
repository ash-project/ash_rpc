# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.OutputFormatter do
  @moduledoc """
  Formats output data from internal format to client format.

  This module handles the conversion of Ash result data to client-expected format.
  It works with the full resource schema including attributes, relationships,
  calculations, and aggregates, then delegates to ValueFormatter for recursive
  type-aware formatting of nested values.

  Key responsibilities:
  - Convert internal atom keys to client field names (e.g., :user_id -> "userId")
  - Preserve untyped map keys exactly as stored
  - Handle complex nested structures with relationships, calculations, aggregates
  - Work with ResultProcessor extraction templates
  - Handle pagination structures and result data
  """

  alias AshRpc.{FieldFormatter, ValueFormatter}

  @doc """
  Formats output data from internal format to client format.

  Converts internal field names to client format while preserving untyped map keys.
  Handles the full resource schema including relationships, calculations, and aggregates.

  ## Parameters
  - `data`: The result data from Ash (internal format)
  - `resource`: The Ash resource module
  - `action_name`: The name of the action that was performed
  - `runtime`: The `AshRpc.Runtime` (output formatter and lookups)

  ## Returns
  The formatted data with internal atom keys converted to client field names,
  except for untyped map keys which are preserved exactly.
  """
  def format(data, resource, action_name, runtime) do
    format_data(data, resource, action_name, runtime)
  end

  defp format_data(data, resource, action_name, runtime) do
    case data do
      map when is_map(map) and not is_struct(map) ->
        format_map(map, resource, action_name, runtime)

      list when is_list(list) ->
        Enum.map(list, fn item ->
          format_data(item, resource, action_name, runtime)
        end)

      other ->
        other
    end
  end

  # Handle pagination structures specially
  defp format_map(
         %{type: maybe_offset_type} = map,
         resource,
         action_name,
         runtime
       )
       when maybe_offset_type in [:offset, :keyset] do
    Enum.into(map, %{}, fn {internal_key, value} ->
      field_or_rel = lookup_field_or_relationship(resource, internal_key, runtime.resource_lookup)

      formatted_value =
        case internal_key do
          :results when is_list(value) ->
            Enum.map(value, fn item ->
              format_data(item, resource, action_name, runtime)
            end)

          _ ->
            ValueFormatter.format(value, field_or_rel, [], :output, runtime)
        end

      output_key = FieldFormatter.format_field_name(internal_key, runtime.output_formatter)
      {output_key, formatted_value}
    end)
  end

  defp format_map(map, resource, _action_name, runtime) do
    Enum.into(map, %{}, fn {internal_key, value} ->
      field_or_rel = lookup_field_or_relationship(resource, internal_key, runtime.resource_lookup)

      formatted_value =
        ValueFormatter.format(value, field_or_rel, [], :output, runtime)

      output_key =
        FieldFormatter.format_field_for_client(
          internal_key,
          Ash.Info.Manifest.get_resource(runtime.resource_lookup, resource),
          runtime.output_formatter
        )

      {output_key, formatted_value}
    end)
  end

  defp lookup_field_or_relationship(resource, field_name, resource_lookup)
       when is_map(resource_lookup) do
    case Ash.Info.Manifest.get_field(resource_lookup, resource, field_name) do
      %Ash.Info.Manifest.Field{} = field -> field
      nil -> Ash.Info.Manifest.get_relationship(resource_lookup, resource, field_name)
    end
  end
end
