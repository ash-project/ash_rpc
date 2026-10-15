# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Trail do
  @moduledoc false
  # A hand-rolled hierarchical label path, stored as a list of strings. Input is
  # a dotted string ("a.b.c") or a list of labels; `strict?: true` accepts only
  # the list form and rejects a string with a message.
  use Ash.Type

  @constraints [strict?: [type: :boolean, default: false]]

  @impl true
  def constraints, do: @constraints

  @impl true
  def storage_type(_constraints), do: {:array, :string}

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    if constraints[:strict?],
      do: {:error, message: "must be a list of labels, got a string"},
      else: {:ok, String.split(value, ".", trim: true)}
  end

  def cast_input(value, _constraints) when is_list(value) do
    if Enum.all?(value, &is_binary/1), do: {:ok, value}, else: :error
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, _constraints) when is_list(value), do: {:ok, value}
  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(value, _constraints), do: {:ok, value}
end
