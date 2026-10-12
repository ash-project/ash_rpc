# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ChecklistBlock do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :title, :string, allow_nil?: false, public?: true

    attribute :items, {:array, :map},
      public?: true,
      constraints: [
        items: [
          fields: [
            text: [type: :string, allow_nil?: false],
            completed: [type: :boolean]
          ]
        ]
      ]

    attribute :is_active?, :boolean, public?: true
    attribute :content_type, :string, public?: true
  end

  calculations do
    calculate :total_items, :integer, expr(length(items)), public?: true
  end
end
