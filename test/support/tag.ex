# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Tag do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults create: [:name]

    read :read do
      primary? true
      pagination offset?: true, countable: true, required?: false
    end
  end
end
