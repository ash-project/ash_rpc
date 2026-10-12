# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Account do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :handle, :string, public?: true
    attribute :email, :string, public?: true
    attribute :embedding, :vector, constraints: [dimensions: 3], public?: true
    # Not public: must never reach the wire, even from a bare struct result.
    attribute :secret, :string
    attribute :internal_notes, :string
  end

  actions do
    defaults [:read, create: [:handle, :email, :embedding, :secret, :internal_notes]]
  end
end
