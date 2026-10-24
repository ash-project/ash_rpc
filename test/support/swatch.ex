# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.SwatchBox do
  @moduledoc false
  # Holds swatches: a `first` aggregate over a declared custom type.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  relationships do
    has_many :swatches, AshRpc.Test.Swatch, destination_attribute: :box_id, public?: true
  end

  aggregates do
    first :first_palette, :swatches, :palette, public?: true
  end

  actions do
    defaults [:read, create: :*]
  end
end

defmodule AshRpc.Test.Swatch do
  @moduledoc false
  # Declared custom types in arrays, union members, calculations and
  # composite attributes.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :palette, AshRpc.Test.Palette, public?: true
    attribute :palettes, {:array, AshRpc.Test.Palette}, public?: true

    attribute :choice, :union,
      public?: true,
      constraints: [types: [palette: [type: AshRpc.Test.Palette], label: [type: :string]]]

    attribute :amount, AshRpc.Test.Amount, public?: true
  end

  relationships do
    belongs_to :box, AshRpc.Test.SwatchBox, public?: true, attribute_public?: true
  end

  calculations do
    calculate :palette_echo, AshRpc.Test.Palette, expr(palette), public?: true
  end

  actions do
    defaults [:read, create: :*]
  end
end
