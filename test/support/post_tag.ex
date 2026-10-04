# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PostTag do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  relationships do
    belongs_to :post, AshRpc.Test.Post,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      attribute_public?: true

    belongs_to :tag, AshRpc.Test.Tag,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      attribute_public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:post_id, :tag_id]]
  end
end
