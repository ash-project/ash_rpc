# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Catalog do
  @moduledoc false
  # Generic actions only; the read exists because the data layer expects a
  # primary key and a primary read.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  alias AshRpc.Test.{Author, Post, PostSettings, PostStats, TaskStats, Voucher}

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  actions do
    defaults [:read]

    action :search_posts, {:array, :struct} do
      constraints items: [instance_of: Post]
      run fn _input, _context -> {:ok, Ash.read!(Post)} end
    end

    action :find_post_via_reactor, :string do
      argument :post_id, :uuid, allow_nil?: false
      run AshRpc.Test.MissingPostReactor
    end

    action :post_ids, {:array, :uuid} do
      run fn _input, _context -> {:ok, Enum.map(Ash.read!(Post), & &1.id)} end
    end

    action :task_stats, TaskStats do
      argument :task_id, :uuid, allow_nil?: false

      run fn _input, _context ->
        {:ok,
         %TaskStats{total_count: 10, completed?: true, is_urgent?: false, average_duration: 2.5}}
      end
    end

    action :task_stats_list, {:array, TaskStats} do
      run fn _input, _context ->
        {:ok,
         [
           %TaskStats{total_count: 1, completed?: true, is_urgent?: true, average_duration: 1.0},
           %TaskStats{total_count: 2, completed?: false, is_urgent?: false}
         ]}
      end
    end

    action :stats_list, {:array, PostStats} do
      run fn _input, _context ->
        {:ok, [%{word_count_1: 1, is_featured?: true}, %{word_count_1: 2, is_featured?: false}]}
      end
    end

    action :raw_rows, {:array, :map} do
      run fn _input, _context ->
        {:ok, [%{"_id" => "a1", "_type" => "doc", "title" => "One"}]}
      end
    end

    action :publication_date, :date do
      run fn _input, _context -> {:ok, ~D[2025-01-15]} end
    end

    action :important_dates, {:array, :date} do
      run fn _input, _context -> {:ok, [~D[2025-01-15], ~D[2025-02-20]]} end
    end

    action :digest, :map do
      constraints fields: [
                    results: [
                      type: {:array, :map},
                      constraints: [
                        items: [
                          fields: [
                            id: [type: :uuid],
                            email: [type: :string],
                            first_name: [type: :string],
                            inserted_at: [type: :utc_datetime_usec]
                          ]
                        ]
                      ]
                    ],
                    settings_rows: [type: {:array, PostSettings}],
                    total_count: [type: :integer]
                  ]

      run fn _input, _context ->
        {:ok,
         %{
           results: [
             %{
               id: "00000000-0000-0000-0000-000000000001",
               email: "ada@example.com",
               first_name: "Ada",
               inserted_at: ~U[2025-01-15 10:00:00.000000Z]
             }
           ],
           settings_rows: [%PostSettings{allow_comments: true, theme_name: "dark"}],
           total_count: 1
         }}
      end
    end

    action :assign, :map do
      constraints fields: [
                    assignee_id: [type: :uuid],
                    assignee_name: [type: :string],
                    reason: [type: :string]
                  ]

      argument :assignee, :struct, allow_nil?: false, constraints: [instance_of: Author]
      argument :reason, :string

      run fn input, _context ->
        assignee = input.arguments.assignee

        {:ok,
         %{
           assignee_id: assignee.id,
           assignee_name: assignee.name,
           reason: Map.get(input.arguments, :reason)
         }}
      end
    end

    action :assign_many, {:array, :map} do
      constraints items: [
                    fields: [assignee_id: [type: :uuid], assignee_name: [type: :string]]
                  ]

      argument :assignees, {:array, :struct}, constraints: [items: [instance_of: Author]]

      run fn input, _context ->
        {:ok,
         Enum.map(
           input.arguments[:assignees] || [],
           &%{assignee_id: &1.id, assignee_name: &1.name}
         )}
      end
    end

    action :redeem_voucher, :map do
      constraints fields: [voucher_code: [type: :string], post_id: [type: :uuid]]
      argument :voucher, :struct, allow_nil?: false, constraints: [instance_of: Voucher]

      run fn input, _context ->
        voucher = input.arguments.voucher
        {:ok, %{voucher_code: voucher.voucher_code, post_id: voucher.post_id}}
      end
    end
  end
end
