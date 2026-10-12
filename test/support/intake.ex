# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Intake do
  @moduledoc false
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  alias AshRpc.Test.{IntakeProfile, IntakeStatus}

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :user_name, :string, allow_nil?: false, public?: true
    attribute :is_active?, :boolean, public?: true
    attribute :version_1, :integer, public?: true

    attribute :settings, :map,
      public?: true,
      constraints: [
        fields: [
          notification_enabled: [type: :boolean, allow_nil?: false],
          theme_name: [type: :string]
        ]
      ]

    attribute :stats, AshRpc.Test.IntakeStats, public?: true
    attribute :deep, AshRpc.Test.IntakeDeep, public?: true
    attribute :preferences, AshRpc.Test.IntakePrefs, public?: true
    attribute :location, AshRpc.Test.GeoPoint, public?: true
    attribute :profile, IntakeProfile, public?: true
    attribute :history, {:array, IntakeProfile}, public?: true
    attribute :section, AshRpc.Test.IntakeSection, public?: true

    attribute :content, :union,
      public?: true,
      constraints: [
        storage: :type_and_value,
        types: [
          data: [type: AshRpc.Test.IntakeData, tag: :content_type, tag_value: "data"],
          simple_value: [type: :string]
        ]
      ]

    attribute :status, :union,
      public?: true,
      constraints: [
        storage: :map_with_tag,
        types: [
          active: [type: IntakeStatus, tag: :status_type, tag_value: "active"],
          inactive: [type: IntakeStatus, tag: :status_type, tag_value: "inactive"]
        ]
      ]
  end

  @accept [
    :user_name,
    :is_active?,
    :version_1,
    :settings,
    :stats,
    :deep,
    :preferences,
    :location,
    :profile,
    :history,
    :section,
    :content,
    :status
  ]

  actions do
    defaults [:read, create: @accept, update: @accept]

    read :search do
      argument :query, :string, allow_nil?: false
      argument :include_deleted?, :boolean, default: false
      argument :filter_by_1?, :boolean, default: false
      filter expr(contains(user_name, ^arg(:query)))
    end

    action :process_data, :map do
      constraints fields: [processed: [type: :boolean], result_count: [type: :integer]]
      argument :input_data, AshRpc.Test.IntakeInput, allow_nil?: false

      run fn input, _context ->
        {:ok, %{processed: input.arguments.input_data.is_valid? == true, result_count: 1}}
      end
    end
  end
end
