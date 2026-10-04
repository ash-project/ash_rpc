# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Comment do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :rating, :integer, public?: true
    attribute :approved, :boolean, default: false, allow_nil?: false, public?: true

    attribute :attachment, :union,
      public?: true,
      constraints: [
        types: [
          file: [type: AshRpc.Test.CommentAttachment],
          note: [type: :string]
        ]
      ]
  end

  relationships do
    belongs_to :post, AshRpc.Test.Post, public?: true, attribute_public?: true
  end

  calculations do
    calculate :weighted_rating, :integer, expr(rating * 2), public?: true
  end

  actions do
    defaults create: [:body, :rating, :approved, :attachment, :post_id]

    read :read do
      primary? true
      pagination offset?: true, keyset?: true, countable: true, required?: false
    end

    read :offset_only do
      pagination offset?: true, countable: true, required?: false
    end

    read :keyset_only do
      pagination keyset?: true, required?: false
    end

    read :rated do
      argument :min_rating, :integer, allow_nil?: false
      filter expr(rating >= ^arg(:min_rating))
      pagination offset?: true, countable: true, required?: false
    end
  end
end
