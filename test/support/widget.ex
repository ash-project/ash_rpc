# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Widget do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :content, :union,
      public?: true,
      constraints: [
        storage: :type_and_value,
        types: [
          text: [type: AshRpc.Test.TextBlock, tag: :content_type, tag_value: "text"],
          checklist: [
            type: AshRpc.Test.ChecklistBlock,
            tag: :content_type,
            tag_value: "checklist"
          ],
          note: [type: :string],
          priority_value: [type: :integer, constraints: [min: 1, max: 10]]
        ]
      ]

    attribute :status, :union,
      public?: true,
      constraints: [
        storage: :map_with_tag,
        types: [
          simple: [type: :map, tag: :status_type, tag_value: "simple"],
          detailed: [type: :map, tag: :status_type, tag_value: "detailed"]
        ]
      ]

    attribute :attachments, {:array, :union},
      public?: true,
      constraints: [
        items: [
          types: [
            file: [
              type: :map,
              tag: :attachment_type,
              tag_value: "file",
              constraints: [
                fields: [
                  filename: [type: :string, allow_nil?: false],
                  size: [type: :integer],
                  mime_type: [type: :string]
                ]
              ]
            ],
            image: [
              type: :map,
              tag: :attachment_type,
              tag_value: "image",
              constraints: [
                fields: [
                  filename: [type: :string, allow_nil?: false],
                  width: [type: :integer],
                  height: [type: :integer],
                  alt_text: [type: :string]
                ]
              ]
            ],
            url: [type: :string]
          ]
        ]
      ]
  end

  relationships do
    belongs_to :post, AshRpc.Test.Post, public?: true, attribute_public?: true
  end

  calculations do
    calculate :featured, AshRpc.Test.WidgetItem, AshRpc.Test.Calculations.FeaturedPost,
      public?: true
  end

  actions do
    defaults [:read, create: [:content, :status, :attachments, :post_id]]
  end
end
