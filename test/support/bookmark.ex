# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Bookmark do
  @moduledoc false
  # No domain of its own: listed in `AshRpc.Test.Domain`, so actions only know
  # their domain from the entrypoint.
  use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :url, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:url], update: [:url]]

    action :echo, :string do
      argument :text, :string, allow_nil?: false
      run fn input, _context -> {:ok, input.arguments.text} end
    end
  end
end
