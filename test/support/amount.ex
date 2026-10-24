# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.AmountBreakdown do
  @moduledoc false
  # Reached only through `Amount`'s declared fields.
  use Ash.TypedStruct

  typed_struct do
    field :net, :decimal
    field :tax_rate, :decimal
  end
end

defmodule AshRpc.Test.AmountValue do
  @moduledoc false
  # A plain struct: `internal` must never reach a client.
  defstruct [:currency, :value, :breakdown, :internal]
end

defmodule AshRpc.Test.Amount do
  @moduledoc false
  # A composite type with struct values carrying an undeclared `internal` key.
  use Ash.Type

  alias AshRpc.Test.AmountValue

  @keys [:currency, :value, :breakdown]

  @impl true
  def storage_type(_constraints), do: :map

  @impl true
  def composite?(_constraints), do: true

  @impl true
  def composite_types(_constraints),
    do: [
      {:currency, :string, []},
      {:value, :decimal, []},
      {:breakdown, AshRpc.Test.AmountBreakdown, []}
    ]

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}
  def cast_input(%AmountValue{} = value, _constraints), do: {:ok, value}

  def cast_input(%{} = value, _constraints) do
    {:ok,
     struct(
       AmountValue,
       Map.new(@keys, &{&1, Map.get(value, &1, Map.get(value, Atom.to_string(&1)))})
       |> Map.put(:internal, :cast)
     )}
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(value, _constraints), do: {:ok, value}
end
