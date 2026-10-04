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

    action :word_count, :integer do
      argument :text, :string, allow_nil?: false

      run fn input, _context ->
        {:ok, input.arguments.text |> String.split() |> length()}
      end
    end
  end
end
