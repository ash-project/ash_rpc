# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Catalog do
  @moduledoc false
  # Generic actions, plus the primary read the data layer expects and
  # `read_with_session_meta` (untyped metadata).
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  alias AshRpc.Test.{
    Account,
    Author,
    PlainSession,
    Post,
    PostSettings,
    PostStats,
    TaskStats,
    Voucher
  }

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

    # A `:struct` with field constraints and no `instance_of`: field-selectable
    # like a typed map.
    action :struct_summary, :struct do
      constraints fields: [
                    title: [type: :string],
                    word_count: [type: :integer],
                    published: [type: :boolean]
                  ]

      run fn _input, _context ->
        {:ok, %{title: "Alpha", word_count: 3, published: true}}
      end
    end

    action :struct_summaries, {:array, :struct} do
      constraints items: [
                    fields: [title: [type: :string], word_count: [type: :integer]]
                  ]

      run fn _input, _context ->
        {:ok, [%{title: "Alpha", word_count: 3}, %{title: "Beta", word_count: 7}]}
      end
    end

    # Untyped data (unconstrained :map, :term): sent exactly as produced. Resource
    # and TypedStruct structs have no Jason encoder, so encoding fails.
    action :untyped_records_map, :map do
      run fn _input, _context -> {:ok, AshRpc.Test.Catalog.untyped_records()} end
    end

    action :untyped_records_term, :term do
      run fn _input, _context -> {:ok, AshRpc.Test.Catalog.untyped_records()} end
    end

    action :untyped_records_list, :term do
      run fn _input, _context ->
        {:ok,
         [
           AshRpc.Test.Catalog.untyped_account("1"),
           AshRpc.Test.Catalog.untyped_account("2"),
           %TaskStats{total_count: 2}
         ]}
      end
    end

    # Untyped data Jason encodes as is.
    action :untyped_value_structs, :map do
      run fn _input, _context ->
        {:ok,
         %{
           at: ~U[2026-01-01 00:00:00Z],
           amount: Decimal.new("1.5"),
           status: :active,
           choice: %Ash.Union{type: :note, value: "n"}
         }}
      end
    end

    # A ForbiddenField inside untyped data: Jason can't encode it.
    action :untyped_forbidden_field, :map do
      run fn _input, _context ->
        {:ok,
         %{
           title: %Ash.ForbiddenField{field: :title, type: :attribute, original_value: "s3cr3t"}
         }}
      end
    end

    # Plain-struct shapes with no field types (see `PlainSession`). Not wire
    # entrypoints: decoration rejects them, so tests build their own manifests.
    action :plain_struct_result, :struct do
      constraints instance_of: PlainSession

      run fn _input, _context ->
        {:ok, %PlainSession{user_id: 1, token: "s3cr3t"}}
      end
    end

    action :bare_struct_result, :struct do
      run fn _input, _context ->
        {:ok, %PlainSession{user_id: 1, token: "s3cr3t"}}
      end
    end

    action :plain_struct_list, {:array, :struct} do
      constraints items: [instance_of: PlainSession]

      run fn _input, _context ->
        {:ok, [%PlainSession{user_id: 1, token: "s3cr3t"}]}
      end
    end

    action :plain_struct_in_typed_map, :map do
      constraints fields: [
                    label: [type: :string],
                    session: [type: :struct, constraints: [instance_of: PlainSession]]
                  ]

      run fn _input, _context ->
        {:ok, %{label: "x", session: %PlainSession{user_id: 1, token: "s3cr3t"}}}
      end
    end

    action :plain_struct_argument, :boolean do
      argument :session, :struct, constraints: [instance_of: PlainSession]
      run fn _input, _context -> {:ok, true} end
    end

    # A generic action's argument named like an attribute (`id`): still an argument.
    action :plain_struct_id_argument, :boolean do
      argument :id, :struct, constraints: [instance_of: PlainSession]
      run fn _input, _context -> {:ok, true} end
    end

    action :plain_struct_in_union, :union do
      constraints types: [
                    label: [type: :string],
                    session: [type: :struct, constraints: [instance_of: PlainSession]]
                  ]

      run fn _input, _context -> {:ok, "x"} end
    end

    action :plain_struct_named, AshRpc.Test.PlainSessionType do
      run fn _input, _context -> {:ok, %PlainSession{user_id: 1, token: "s3cr3t"}} end
    end

    action :plain_struct_in_embedded, :struct do
      constraints instance_of: AshRpc.Test.SessionHolder
      run fn _input, _context -> {:ok, nil} end
    end

    # `instance_of` a TypedStruct: `:struct` doesn't take fields from it, so
    # the manifest has none (use `TaskStats` as the type instead).
    action :typed_struct_instance_of, :struct do
      constraints instance_of: TaskStats
      run fn _input, _context -> {:ok, %TaskStats{total_count: 1}} end
    end

    # An empty field list on a plain struct module is still untyped: the
    # struct's own fields would reach the client.
    action :plain_struct_empty_fields, :struct do
      constraints instance_of: PlainSession, fields: []
      run fn _input, _context -> {:ok, %PlainSession{user_id: 1, token: "s3cr3t"}} end
    end

    # An empty TypedStruct is typed: nothing to select, nothing leaks.
    action :empty_typed_struct, AshRpc.Test.EmptyStats do
      run fn _input, _context -> {:ok, %AshRpc.Test.EmptyStats{}} end
    end

    # An empty field list without `instance_of` is untyped: the returned
    # struct's own fields would reach the client.
    action :empty_struct_fields, :struct do
      constraints fields: []
      run fn _input, _context -> {:ok, %PlainSession{user_id: 1, token: "s3cr3t"}} end
    end

    # A recursive named type with no untyped struct in it.
    action :tree_result, AshRpc.Test.TreeNode do
      run fn _input, _context -> {:ok, %{label: "root", children: []}} end
    end

    # Composite custom types (see composite_types.ex). Not wire entrypoints:
    # decoration rejects the first seven, and the rest only show what stays allowed
    # (apart from `composite_new_type_plain_argument` and `composite_deepening`).
    action :composite_plain_result, AshRpc.Test.PlainPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_typed_struct_instance_of, AshRpc.Test.TypedStructPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_storage_key, AshRpc.Test.StoredPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_plain_list, AshRpc.Test.PlainPoints do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_nested, AshRpc.Test.OuterPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_new_type, AshRpc.Test.PlainPointNewType do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_argument, :boolean do
      argument :pair, AshRpc.Test.PlainPoint
      run fn _input, _context -> {:ok, true} end
    end

    action :composite_typed_struct_entry, AshRpc.Test.TaskStatsPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :opaque_custom_result, AshRpc.Test.Palette do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_disabled, AshRpc.Test.DisabledPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :typed_struct_fields_custom, AshRpc.Test.TypedStructFieldsPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_recursive, AshRpc.Test.RecursivePoint do
      run fn _input, _context -> {:ok, nil} end
    end

    action :composite_new_type_plain_argument, :boolean do
      argument :p, AshRpc.Test.ConstrainedPointNewType, constraints: [plain?: true]
      run fn _input, _context -> {:ok, true} end
    end

    action :composite_new_type_clean_argument, :boolean do
      argument :p, AshRpc.Test.ConstrainedPointNewType, constraints: [plain?: false]
      run fn _input, _context -> {:ok, true} end
    end

    action :composite_new_type_default_argument, :boolean do
      argument :p, AshRpc.Test.ConstrainedPointNewType
      run fn _input, _context -> {:ok, true} end
    end

    action :composite_deepening, AshRpc.Test.DeepeningPoint do
      run fn _input, _context -> {:ok, nil} end
    end

    # A read whose metadata is an untyped struct.
    read :read_with_session_meta do
      metadata :session, :struct, constraints: [instance_of: PlainSession]
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

  @doc false
  def untyped_records do
    %{
      account: untyped_account("1"),
      stats: %TaskStats{total_count: 2, is_urgent?: true}
    }
  end

  @doc false
  def untyped_account(n) do
    %Account{
      id: "00000000-0000-0000-0000-00000000000#{n}",
      handle: "h#{n}",
      email: "e#{n}@x",
      secret: "s3cr3t",
      internal_notes: "notes"
    }
  end
end
