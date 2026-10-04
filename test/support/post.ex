# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Post do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  alias AshRpc.Test.{Calculations, Changes}

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :view_count, :integer, default: 0, public?: true
    attribute :stats, AshRpc.Test.PostStats, public?: true
    attribute :settings, AshRpc.Test.PostSettings, public?: true
    attribute :slug, :string, public?: true
    attribute :data, :map, public?: true
  end

  identities do
    identity :unique_slug, [:slug], pre_check_with: AshRpc.Test.Domain
  end

  relationships do
    belongs_to :author, AshRpc.Test.Author, public?: true, attribute_public?: true
    belongs_to :secret, AshRpc.Test.Secret, public?: true, attribute_public?: true

    has_many :comments, AshRpc.Test.Comment, public?: true

    has_many :comments_offset, AshRpc.Test.Comment do
      public? true
      read_action :offset_only
    end

    has_many :comments_keyset, AshRpc.Test.Comment do
      public? true
      read_action :keyset_only
    end

    many_to_many :tags, AshRpc.Test.Tag do
      public? true
      through AshRpc.Test.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
    end
  end

  calculations do
    calculate :title_length, :integer, expr(string_length(title)), public?: true

    calculate :excerpt, :string, Calculations.Excerpt do
      public? true
      argument :length, :integer, allow_nil?: false
    end

    calculate :scored_stats, AshRpc.Test.PostStats, Calculations.ScoredStats do
      public? true
      argument :boost, :integer, allow_nil?: false
    end

    calculate :self_post, :struct, Calculations.SelfPost do
      public? true
      constraints instance_of: __MODULE__
    end
  end

  aggregates do
    count :comment_count, :comments, public?: true

    count :approved_comment_count, :comments do
      public? true
      filter expr(approved == true)
    end

    exists :has_comments, :comments, public?: true
    avg :avg_rating, :comments, :rating, public?: true
    max :max_rating, :comments, :rating, public?: true

    first :first_comment_body, :comments, :body do
      public? true
      sort body: :asc
    end

    list :comment_bodies, :comments, :body do
      public? true
      sort body: :asc
    end
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_slug

    create :create do
      primary? true
      accept [:title, :view_count, :stats, :settings, :author_id, :secret_id, :slug, :data]
    end

    update :update do
      primary? true
      accept [:title, :view_count, :slug, :data]
    end

    read :read_with_metadata do
      metadata :total_score, :integer, allow_nil?: false, default: 0
      metadata :meta_1, :string
      metadata :is_cached?, :boolean

      metadata :breakdown, :map,
        constraints: [fields: [top_score: [type: :integer], tag_names: [type: {:array, :string}]]]

      metadata :extra, :map

      prepare Changes.PutMetadataOnRead
    end

    create :create_with_metadata do
      accept [:title, :view_count]
      metadata :total_score, :integer, allow_nil?: false, default: 0
      metadata :meta_1, :string
      metadata :is_cached?, :boolean

      metadata :breakdown, :map,
        constraints: [fields: [top_score: [type: :integer], tag_names: [type: {:array, :string}]]]

      metadata :extra, :map

      change Changes.PutMetadataOnResult
    end

    update :update_with_metadata do
      accept [:title, :view_count]
      require_atomic? false
      metadata :total_score, :integer, allow_nil?: false, default: 0
      metadata :meta_1, :string
      metadata :is_cached?, :boolean

      metadata :breakdown, :map,
        constraints: [fields: [top_score: [type: :integer], tag_names: [type: {:array, :string}]]]

      metadata :extra, :map

      change Changes.PutMetadataOnResult
    end

    destroy :destroy_with_metadata do
      require_atomic? false
      metadata :total_score, :integer, allow_nil?: false, default: 0
      metadata :meta_1, :string
      metadata :is_cached?, :boolean

      metadata :breakdown, :map,
        constraints: [fields: [top_score: [type: :integer], tag_names: [type: {:array, :string}]]]

      metadata :extra, :map

      change Changes.PutMetadataOnResult
    end

    update :merge_data do
      accept []
      require_atomic? false
      argument :data, :map
      change Changes.MergeData
    end

    action :echo_map, :map do
      argument :payload, :map
      run fn input, _context -> {:ok, input.arguments.payload} end
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
