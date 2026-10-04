# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Ledger do
  @moduledoc false
  # Attribute names deliberately collide with page-map keys (`count`) and
  # arrays allow nil items, to guard result extraction and output formatting.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :count, :union,
      public?: true,
      constraints: [types: [number: [type: :integer], label: [type: :string]]]

    attribute :labels, {:array, :string}, public?: true, constraints: [nil_items?: true]

    attribute :entries, {:array, :union},
      public?: true,
      constraints: [
        nil_items?: true,
        items: [types: [number: [type: :integer], label: [type: :string]]]
      ]
  end

  actions do
    defaults [:read, create: [:count, :labels, :entries]]

    read :paged do
      pagination offset?: true, countable: true, required?: false
    end
  end
end
