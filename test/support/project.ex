# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Project do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  alias AshRpc.Test.{Calculations, ProjectMeta}

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :metadata, ProjectMeta, public?: true
    attribute :history, {:array, ProjectMeta}, public?: true
    attribute :palette, AshRpc.Test.Palette, public?: true
    attribute :trail, AshRpc.Test.Trail, public?: true
    attribute :strict_trail, AshRpc.Test.Trail, public?: true, constraints: [strict?: true]
    attribute :due_date, :date, public?: true
    attribute :started_at, :utc_datetime, public?: true
    attribute :estimate, :duration, public?: true
    attribute :breaks, {:array, :duration}, public?: true
    attribute :priority, :atom, public?: true, constraints: [one_of: [:low, :medium, :high]]
    attribute :stats, AshRpc.Test.ProjectStats, public?: true
  end

  relationships do
    has_many :notes, AshRpc.Test.ProjectNote, public?: true
  end

  calculations do
    calculate :summary, AshRpc.Test.ProjectStats, Calculations.ProjectSummary, public?: true

    calculate :report, :map, Calculations.ProjectReport do
      public? true

      constraints fields: [
                    rows: [type: {:array, ProjectMeta}],
                    total: [type: :integer, allow_nil?: false]
                  ]
    end

    calculate :self, :struct, Calculations.SelfRecords do
      public? true
      constraints instance_of: __MODULE__
      argument :prefix, :string
    end

    calculate :is_late, :boolean, Calculations.IsLate, public?: true
    calculate :days_left, :integer, Calculations.DaysLeft, public?: true
  end

  aggregates do
    first :first_note_meta, :notes, :meta, public?: true
    first :first_note_author_info, :notes, :author_info, public?: true
  end

  @accept [
    :metadata,
    :history,
    :palette,
    :trail,
    :strict_trail,
    :due_date,
    :started_at,
    :estimate,
    :breaks,
    :priority,
    :stats
  ]

  actions do
    defaults [:read, create: @accept, update: @accept]

    action :process_meta, :map do
      constraints fields: [processed: [type: :boolean], priority: [type: :integer]]
      argument :meta, ProjectMeta, allow_nil?: false
      argument :options, :map

      run fn input, _context ->
        {:ok, %{processed: true, priority: input.arguments.meta.priority_score}}
      end
    end

    action :process_meta_batch, {:array, :map} do
      constraints items: [
                    fields: [processed: [type: :boolean], priority: [type: :integer]]
                  ]

      argument :metas, {:array, ProjectMeta}, allow_nil?: false

      run fn input, _context ->
        {:ok, Enum.map(input.arguments.metas, &%{processed: true, priority: &1.priority_score})}
      end
    end
  end
end
