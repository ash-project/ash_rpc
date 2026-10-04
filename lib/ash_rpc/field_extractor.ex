# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldExtractor do
  @moduledoc """
  Unified field extraction for different data structures.

  This module provides a consistent interface for extracting field values from
  different Elixir data structures (maps, keyword lists, tuples, structs).

  ## Strategy

  All data structures are normalized to maps before extraction, providing a single
  code path for field access. This eliminates type-specific extraction logic and
  makes the code easier to understand and maintain.

  ## Supported Types

  - **Maps**: Used as-is
  - **Structs**: Converted to maps via `Map.from_struct/1`
  - **Keyword lists**: Converted to maps
  - **Tuples**: Converted to maps using extraction template indices
  """

  @doc """
  Normalizes a data structure for field extraction.

  Converts all supported data types to maps, using the extraction template
  when needed (e.g., for tuple index mapping).

  ## Parameters

  - `data` - The data structure to normalize (map, struct, keyword list, or tuple)
  - `extraction_template` - Template containing field metadata (used for tuples)

  ## Returns

  A map representation of the data suitable for field extraction.

  ## Examples

      # Map - returned as-is
      iex> normalize_for_extraction(%{foo: 1, bar: 2}, [])
      %{foo: 1, bar: 2}

      # Keyword list - converted to map
      iex> normalize_for_extraction([foo: 1, bar: 2], [])
      %{foo: 1, bar: 2}

      # Tuple - converted using template indices
      iex> template = [%{field_name: :foo, index: 0}, %{field_name: :bar, index: 1}]
      iex> normalize_for_extraction({1, 2}, template)
      %{foo: 1, bar: 2}
  """
  def normalize_for_extraction(data, extraction_template) do
    cond do
      is_tuple(data) ->
        convert_tuple_to_map(data, extraction_template)

      is_list(data) and data != [] and Keyword.keyword?(data) ->
        Map.new(data)

      is_map(data) and is_struct(data) ->
        Map.from_struct(data)

      is_map(data) ->
        data

      true ->
        # Fallback: return as-is (will likely fail extraction, but safe)
        data
    end
  end

  # Private: Convert tuple to map using extraction template
  #
  # The extraction template for tuples contains field metadata including the
  # positional index for each field. This allows us to map tuple positions
  # to named fields.
  #
  # Template format: [%{field_name: atom, index: integer}, ...]
  defp convert_tuple_to_map(tuple, extraction_template) do
    Enum.reduce(extraction_template, %{}, fn
      %{field_name: field_name, index: index}, acc ->
        value = elem(tuple, index)
        Map.put(acc, field_name, value)

      # Skip non-tuple field specs (handles mixed templates gracefully)
      _other, acc ->
        acc
    end)
  end
end
