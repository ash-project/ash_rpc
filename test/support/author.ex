# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Author do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :is_active?, :boolean, default: true, public?: true
  end

  identities do
    identity :name_active, [:name, :is_active?], pre_check_with: AshRpc.Test.Domain
  end

  relationships do
    has_many :posts, AshRpc.Test.Post, public?: true
  end

  calculations do
    calculate :is_prolific?, :boolean, expr(post_count > 1), public?: true
  end

  aggregates do
    count :post_count, :posts, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name, :is_active?], update: [:name, :is_active?]]

    read :me do
      filter expr(id == ^actor(:id))
    end

    update :update_me do
      accept [:name]
    end

    destroy :destroy_me
  end
end
