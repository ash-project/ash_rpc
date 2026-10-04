# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.NoteReply do
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
    attribute :body, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :note, AshRpc.Test.Note, public?: true, attribute_public?: true
  end

  actions do
    defaults create: [:body, :note_id]

    read :read do
      primary? true
      pagination offset?: true, countable: true, required?: false
    end
  end
end
