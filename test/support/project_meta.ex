# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ProjectMetaDetail do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :note, :string, public?: true
    attribute :level, :integer, public?: true
  end
end

defmodule AshRpc.Test.ProjectMeta do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :category, :string, allow_nil?: false, public?: true
    attribute :priority_score, :integer, public?: true
    attribute :is_urgent, :boolean, public?: true
    attribute :deadline, :date, public?: true

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:draft, :active, :archived]]

    attribute :detail, AshRpc.Test.ProjectMetaDetail, public?: true
    # Not public: selecting it over the wire is an unknown field.
    attribute :internal_notes, :string
    # Union tag for `ProjectNote.author_info`'s `meta` member.
    attribute :info_type, :string, public?: true
  end

  # The defaults accept only public attributes; `internal_notes` is accepted
  # too so a stored private value exists for the never-on-the-wire checks.
  @accept [
    :category,
    :priority_score,
    :is_urgent,
    :deadline,
    :status,
    :detail,
    :internal_notes,
    :info_type
  ]

  actions do
    defaults [:read, :destroy, create: @accept, update: @accept]
  end

  calculations do
    calculate :display_category, :string, expr("category:" <> category), public?: true

    calculate :adjusted_priority,
              :integer,
              expr((priority_score || 0) * ^arg(:multiplier)) do
      public? true
      argument :multiplier, :integer, allow_nil?: false
    end
  end
end
