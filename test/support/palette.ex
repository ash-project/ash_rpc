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
    primary = Map.get(value, :primary, Map.get(value, "primary"))
    secondary = Map.get(value, :secondary, Map.get(value, "secondary"))

    if is_binary(primary) and is_binary(secondary),
      do: {:ok, %{primary: primary, secondary: secondary}},
      else: :error
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, _constraints), do: {:ok, value}
end
