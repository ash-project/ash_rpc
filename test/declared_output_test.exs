# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.DeclaredOutputTest do
  # Typed maps and structs formatted for output without extraction (typed
  # route results, channel payloads, action metadata, unselected union
  # members) emit only their declared fields, under decorated client names.
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias AshRpc.{Introspection, Runtime, ValueFormatter}
  alias AshRpc.Test.{AmountValue, Catalog, Intake, Place, TaskStats, Widget}

  setup do
    %{rt: Runtime.new(AshRpc.Test.Profile)}
  end

  defp output(value, type, rt), do: ValueFormatter.format(value, type, [], :output, rt)

  defp returns(rt, resource, action), do: Introspection.get_action!(rt, resource, action).returns

  defp field_type(rt, resource, field),
    do: Manifest.get_field(rt.resource_lookup, resource, field).type

  test "a composite struct value (Amount) doesn't raise and emits declared fields only", %{
    rt: rt
  } do
    value = %AmountValue{
      currency: "EUR",
      value: Decimal.new("1.50"),
      breakdown: %{net: Decimal.new("1.20"), tax_rate: Decimal.new("0.25")},
      internal: :secret
    }

    assert output(value, returns(rt, Catalog, :amount_result), rt) == %{
             "currency" => "EUR",
             "value" => Decimal.new("1.50"),
             "breakdown" => %{"net" => Decimal.new("1.20"), "taxRate" => Decimal.new("0.25")}
           }
  end

  test "a TypedStruct struct value emits its declared fields under override names", %{rt: rt} do
    value = %TaskStats{
      total_count: 10,
      completed?: true,
      is_urgent?: false,
      average_duration: 2.5
    }

    assert output(value, returns(rt, Catalog, :task_stats), rt) == %{
             "totalCount" => 10,
             "completed" => true,
             "isUrgent" => false,
             "averageDuration" => 2.5
           }
  end

  test "a container no decoration reached names declared fields from the mapping source, then the formatter",
       %{rt: rt} do
    # Without its lookup entry, TaskStats resolves to an undecorated definition.
    rt = %{rt | type_lookup: Map.delete(rt.type_lookup, TaskStats)}
    value = %TaskStats{total_count: 1, completed?: true, is_urgent?: true}

    assert output(value, TaskStats, rt) == %{
             "totalCount" => 1,
             "completed" => true,
             "isUrgent" => true,
             "averageDuration" => nil
           }
  end

  test "a plain typed map drops an undeclared key", %{rt: rt} do
    assert output(%{theme_name: "x", extra: 1}, field_type(rt, Intake, :settings), rt) ==
             %{"themeName" => "x"}
  end

  test "a string key equal to an internal name is kept under its client name", %{rt: rt} do
    assert output(%{"theme_name" => "x", "extra" => 1}, field_type(rt, Intake, :settings), rt) ==
             %{"themeName" => "x"}
  end

  test "a string key in client casing is not a declared field", %{rt: rt} do
    assert output(%{"themeName" => "x"}, field_type(rt, Intake, :settings), rt) == %{}
  end

  test "override names come from decoration", %{rt: rt} do
    assert output(%{word_count_1: 3}, AshRpc.Test.PostStats, rt) == %{"wordCount1" => 3}
  end

  test "decorated names win over the runtime's formatter", %{rt: rt} do
    rt = %{rt | output_formatter: :pascal_case}

    assert output(%{theme_name: "x"}, field_type(rt, Intake, :settings), rt) ==
             %{"themeName" => "x"}
  end

  test "declared fields the value lacks are not added as nil", %{rt: rt} do
    assert output(%{theme_name: "x"}, field_type(rt, Intake, :settings), rt) ==
             %{"themeName" => "x"}
  end

  test "keyword and tuple values keep working and drop undeclared keys", %{rt: rt} do
    assert output(
             [priority: 8, category: "work", extra: 1],
             field_type(rt, Place, :options),
             rt
           ) == %{"priority" => 8, "category" => "work"}

    assert output({1.5, 2.5}, field_type(rt, Place, :coordinates), rt) ==
             %{"latitude" => 1.5, "longitude" => 2.5}
  end

  test "an unselected union member's typed map drops undeclared keys", %{rt: rt} do
    value = [%{file: %{filename: "a.txt", extra: 1}}]

    assert output(value, field_type(rt, Widget, :attachments), rt) ==
             [%{"file" => %{"filename" => "a.txt"}}]
  end

  describe ":map_with_tag members" do
    @tagged [
      storage: :map_with_tag,
      types: [
        file: [
          type: :map,
          tag: :kind,
          tag_value: "file",
          constraints: [fields: [name: [type: :string]]]
        ]
      ]
    ]

    test "a typed-map member that doesn't declare its tag drops it", %{rt: rt} do
      value = %{file: %{kind: "file", name: "a.txt"}}

      assert ValueFormatter.format(value, :union, @tagged, :output, rt) ==
               %{"file" => %{"name" => "a.txt"}}
    end

    test "an untyped member keeps its tag under the formatter's name", %{rt: rt} do
      value = %{simple: %{:status_type => "simple", "note" => "x"}}

      assert output(value, field_type(rt, Widget, :status), rt) ==
               %{"simple" => %{"statusType" => "simple", "note" => "x"}}
    end
  end

  test "action metadata with a struct value emits declared fields only" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "With amount"})

    assert %{"success" => true, "data" => records} =
             AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
               "action" => "read_posts_with_amount_meta",
               "fields" => ["id"],
               "metadataFields" => ["amount"]
             })

    assert %{"amount" => amount} = Enum.find(records, &(&1["id"] == post.id))
    assert amount == %{"currency" => "EUR", "value" => Decimal.new("3"), "breakdown" => nil}
  end
end
