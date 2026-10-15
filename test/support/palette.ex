# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Palette do
  @moduledoc false
  # A hand-rolled type with map storage: the runtime must treat it as a
  # primitive, not as a typed map it can select fields from.
  use Ash.Type

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(%{} = value, _constraints) do
    primary = fetch(value, :primary)
    secondary = fetch(value, :secondary)
    accent_color = fetch(value, :accent_color)

    cond do
      not (is_binary(primary) and is_binary(secondary)) ->
        :error

      is_nil(accent_color) ->
        {:ok, %{primary: primary, secondary: secondary}}

      is_binary(accent_color) ->
        {:ok, %{primary: primary, secondary: secondary, accent_color: accent_color}}

      true ->
        :error
    end
  end

  def cast_input(_value, _constraints), do: :error

  defp fetch(value, key), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, _constraints), do: {:ok, value}
end
