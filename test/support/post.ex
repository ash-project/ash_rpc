# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Post do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :view_count, :integer, default: 0, public?: true
    attribute :stats, AshRpc.Test.PostStats, public?: true
    attribute :settings, AshRpc.Test.PostSettings, public?: true
  end

  relationships do
    belongs_to :author, AshRpc.Test.Author, public?: true, attribute_public?: true
    belongs_to :secret, AshRpc.Test.Secret, public?: true, attribute_public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:title, :view_count, :stats, :settings, :author_id, :secret_id]
    end

    update :update do
      primary? true
      accept [:title, :view_count]
    end

    action :stats_summary, AshRpc.Test.PostStats do
      run fn _input, _context -> {:ok, %{word_count_1: 3, is_featured?: true}} end
    end

    action :totals, :map do
      constraints fields: [
                    total: [type: :integer],
                    by_kind: [type: :map, constraints: [fields: [drafts: [type: :integer]]]]
                  ]

      run fn _input, _context -> {:ok, %{total: 2, by_kind: %{drafts: 1}}} end
    end

    action :location, :tuple do
      constraints fields: [lat: [type: :float], lng: [type: :float]]
      run fn _input, _context -> {:ok, {1.0, 2.0}} end
    end

    action :payload, :union do
      constraints types: [
                    text: [type: :string],
                    stats: [type: AshRpc.Test.PostStats]
                  ]

      run fn _input, _context -> {:ok, "hello"} end
    end

    action :ping do
      run fn _input, _context -> :ok end
    end

    action :word_count, :integer do
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, input.arguments.text |> String.split() |> length()}
      end
    end
  end
end
