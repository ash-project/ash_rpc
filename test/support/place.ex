# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Place do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :options, :keyword,
      public?: true,
      constraints: [
        fields: [
          priority: [type: :integer, allow_nil?: false, constraints: [min: 1, max: 10]],
          category: [type: :string, constraints: [max_length: 50]],
          notify: [type: :boolean]
        ]
      ]

    attribute :coordinates, :tuple,
      public?: true,
      constraints: [
        fields: [
          latitude: [type: :float, allow_nil?: false],
          longitude: [type: :float, allow_nil?: false]
        ]
      ]

    attribute :location, AshRpc.Test.GeoPoint, public?: true
    attribute :route, {:array, AshRpc.Test.GeoPoint}, public?: true
  end

  calculations do
    calculate :origin, AshRpc.Test.GeoPoint, AshRpc.Test.Calculations.Origin, public?: true
  end

  actions do
    defaults [:read, create: [:options, :coordinates, :location, :route]]

    action :keyword_options, :keyword do
      constraints fields: [
                    priority: [type: :integer, allow_nil?: false],
                    category: [type: :string, allow_nil?: false],
                    notify: [type: :boolean, allow_nil?: false],
                    theme: [
                      type: :atom,
                      allow_nil?: false,
                      constraints: [one_of: [:light, :dark, :auto]]
                    ]
                  ]

      run fn _input, _context ->
        {:ok, [priority: 8, category: "work", notify: true, theme: :dark]}
      end
    end

    action :coordinates_info, :tuple do
      constraints fields: [
                    latitude: [type: :float, allow_nil?: false],
                    longitude: [type: :float, allow_nil?: false],
                    altitude: [type: :integer]
                  ]

      run fn _input, _context -> {:ok, {37.7749, -122.4194, 50}} end
    end

    action :geo_point, AshRpc.Test.GeoPoint do
      run fn _input, _context -> {:ok, {3.0, 4.0, true}} end
    end
  end
end
