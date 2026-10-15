# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldProcessing.FieldSelector.Validation do
  @moduledoc """
  Field validation helpers for the FieldSelector module.

  Provides validation functions for checking field selections are valid
  and properly structured.
  """

  @doc """
  Checks for duplicate field names in a field selection list.

  String names are resolved with `resolve` (client name → internal atom)
  before comparing. Throws `{:duplicate_field, field_name, path}` if
  duplicates are found.
  """
  def check_for_duplicates(fields, path, resolve) when is_function(resolve, 1) do
    field_names =
      Enum.flat_map(fields, fn
        field_name when is_atom(field_name) -> [field_name]
        field_name when is_binary(field_name) -> [resolve.(field_name)]
        %{} = field_map -> Enum.map(Map.keys(field_map), &resolve_key(&1, resolve))
        {field_name, _field_spec} -> [field_name]
        invalid_field -> throw({:invalid_field_type, invalid_field, path})
      end)

    duplicate_fields =
      field_names
      |> Enum.frequencies()
      |> Enum.filter(fn {_field, count} -> count > 1 end)
      |> Enum.map(fn {field, _count} -> field end)

    if !Enum.empty?(duplicate_fields) do
      throw({:duplicate_field, List.first(duplicate_fields), path})
    end
  end

  @doc """
  Validates that nested fields are non-empty for fields that require selection.

  Throws appropriate errors if validation fails.
  """
  def validate_non_empty(nested_fields, field_name, path, error_type \\ :relationship) do
    if not is_list(nested_fields) do
      throw({:unsupported_field_combination, :relationship, field_name, nested_fields, path})
    end

    if nested_fields == [] do
      throw({:requires_field_selection, error_type, field_name, path})
    end
  end

  defp resolve_key(key, resolve) when is_binary(key), do: resolve.(key)
  defp resolve_key(key, _resolve), do: key
end
