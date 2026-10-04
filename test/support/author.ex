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

  relationships do
    has_many :posts, AshRpc.Test.Post, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:name, :is_active?], update: [:name, :is_active?]]
  end
end
