# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Note do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  multitenancy do
    strategy :attribute
    attribute :workspace_id
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :workspace_id, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
  end

  relationships do
    has_many :replies, AshRpc.Test.NoteReply, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end
end
