# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ProjectNote do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :body, :string, public?: true
    attribute :meta, AshRpc.Test.ProjectMeta, public?: true

    attribute :author_info, :union,
      public?: true,
      constraints: [
        types: [
          meta: [type: AshRpc.Test.ProjectMeta, tag: :info_type, tag_value: "meta"],
          anonymous: [type: :string]
        ]
      ]
  end

  relationships do
    belongs_to :project, AshRpc.Test.Project, public?: true, attribute_public?: true
  end

  actions do
    defaults [:read, create: [:body, :meta, :author_info, :project_id]]
  end
end
