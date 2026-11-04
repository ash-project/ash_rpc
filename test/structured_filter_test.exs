# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.StructuredFilterTest do
  @moduledoc """
  Filters on structured fields through `AshRpc.run_action/3`: a value is
  stored as the same action input would be, so equality matches it, an
  invalid one is an error, and an operator that means nothing for the value
  (ordering a structured value, comparing a record) is unknown.
  """
  use ExUnit.Case, async: false

  alias AshRpc.Test.{Place, Post, Widget}

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp create!(action, input) do
    assert %{"success" => true, "data" => data} =
             run(%{"action" => action, "input" => input, "fields" => ["id"]})

    data["id"]
  end

  defp ids(action, filter) do
    case run(%{"action" => action, "fields" => ["id"], "filter" => filter}) do
      %{"success" => true, "data" => data} -> data |> Enum.map(& &1["id"]) |> Enum.sort()
      other -> flunk("filter #{inspect(filter)} failed: #{inspect(other)}")
    end
  end

  defp error(action, filter) do
    assert %{"success" => false, "errors" => [error | _]} =
             run(%{"action" => action, "fields" => ["id"], "filter" => filter})

    error
  end

  setup do
    Enum.each([Widget, Place, Post], fn resource ->
      resource |> Ash.read!(authorize?: false) |> Enum.each(&Ash.destroy!(&1, authorize?: false))
    end)

    :ok
  end

  describe "unions" do
    setup do
      note = create!("create_widget", %{"content" => %{"note" => "remember"}})
      priority = create!("create_widget", %{"content" => %{"priorityValue" => 8}})

      status =
        create!("create_widget", %{
          "status" => %{"simple" => %{"message" => "ok"}},
          "attachments" => [
            %{"file" => %{"filename" => "f.txt", "size" => 10}},
            %{"url" => "https://a.example"}
          ]
        })

      %{note: note, priority: priority, status: status}
    end

    test "eq matches the member value", ctx do
      assert ids("list_widgets", %{"content" => %{"eq" => %{"note" => "remember"}}}) == [ctx.note]

      assert ids("list_widgets", %{"content" => %{"eq" => %{"priorityValue" => 8}}}) ==
               [ctx.priority]
    end

    test "eq with another value matches nothing" do
      assert ids("list_widgets", %{"content" => %{"eq" => %{"note" => "forget"}}}) == []
    end

    test "notEq and in", ctx do
      assert ids("list_widgets", %{"content" => %{"notEq" => %{"note" => "remember"}}}) ==
               [ctx.priority]

      assert ids("list_widgets", %{
               "content" => %{"in" => [%{"note" => "remember"}, %{"priorityValue" => 8}]}
             }) == Enum.sort([ctx.note, ctx.priority])
    end

    test "eq on a map_with_tag union", ctx do
      assert ids("list_widgets", %{"status" => %{"eq" => %{"simple" => %{"message" => "ok"}}}}) ==
               [ctx.status]
    end

    test "has and eq on an array of unions", ctx do
      assert ids("list_widgets", %{"attachments" => %{"has" => %{"url" => "https://a.example"}}}) ==
               [ctx.status]

      assert ids("list_widgets", %{
               "attachments" => %{"has" => %{"file" => %{"filename" => "f.txt", "size" => 10}}}
             }) == [ctx.status]

      assert ids("list_widgets", %{
               "attachments" => %{
                 "eq" => [
                   %{"file" => %{"filename" => "f.txt", "size" => 10}},
                   %{"url" => "https://a.example"}
                 ]
               }
             }) == [ctx.status]
    end

    test "structured values inside and/or/not", ctx do
      assert ids("list_widgets", %{
               "or" => [
                 %{"content" => %{"eq" => %{"note" => "remember"}}},
                 %{"status" => %{"eq" => %{"simple" => %{"message" => "ok"}}}}
               ]
             }) == Enum.sort([ctx.note, ctx.status])

      assert ids("list_widgets", %{
               "and" => [
                 %{"content" => %{"isNil" => false}},
                 %{"not" => [%{"content" => %{"eq" => %{"note" => "remember"}}}]}
               ]
             }) == [ctx.priority]
    end

    test "a value its member's constraints reject is an invalid_filter_value" do
      error = error("list_widgets", %{"content" => %{"eq" => %{"priorityValue" => 99}}})
      assert error["type"] == "invalid_filter_value"
      assert error["path"] == ["filter", "content", "eq"]
    end

    test "an ordering operator is unknown" do
      error = error("list_widgets", %{"content" => %{"lessThan" => %{"priorityValue" => 9}}})
      assert error["type"] == "unknown_filter_operator"
    end
  end

  describe "keywords and tuples" do
    setup do
      work =
        create!("create_place", %{
          "options" => %{"priority" => 3, "category" => "work"},
          "coordinates" => %{"latitude" => 1.5, "longitude" => 2.5}
        })

      bare = create!("create_place", %{"options" => %{"priority" => 5}})
      %{work: work, bare: bare}
    end

    test "keyword eq and in", ctx do
      assert ids("list_places", %{
               "options" => %{"eq" => %{"priority" => 3, "category" => "work"}}
             }) ==
               [ctx.work]

      assert ids("list_places", %{"options" => %{"eq" => %{"priority" => 5}}}) == [ctx.bare]

      assert ids("list_places", %{
               "options" => %{
                 "in" => [%{"priority" => 3, "category" => "work"}, %{"priority" => 5}]
               }
             }) == Enum.sort([ctx.work, ctx.bare])
    end

    test "tuple eq", ctx do
      assert ids("list_places", %{
               "coordinates" => %{"eq" => %{"latitude" => 1.5, "longitude" => 2.5}}
             }) == [ctx.work]
    end

    test "a keyword value missing a required key is an invalid_filter_value" do
      error = error("list_places", %{"options" => %{"eq" => %{"category" => "work"}}})
      assert error["type"] == "invalid_filter_value"
    end

    test "a keyword value its constraints reject is an invalid_filter_value" do
      error = error("list_places", %{"options" => %{"eq" => %{"priority" => 99}}})
      assert error["type"] == "invalid_filter_value"
    end

    test "an ordering operator is unknown" do
      error = error("list_places", %{"options" => %{"greaterThan" => %{"priority" => 1}}})
      assert error["type"] == "unknown_filter_operator"
    end
  end

  describe "records (resources and embedded resources)" do
    test "an embedded resource takes isNil only" do
      Ash.create!(Post, %{title: "with", settings: %{theme_name: "dark"}})
      Ash.create!(Post, %{title: "without"})

      assert %{"success" => true, "data" => [%{"title" => "with"}]} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "filter" => %{"settings" => %{"isNil" => false}}
               })

      for op <- ["eq", "notEq"] do
        error = error("list_posts", %{"settings" => %{op => %{"themeName" => "dark"}}})
        assert error["type"] == "unknown_filter_operator"
      end

      error = error("list_posts", %{"settings" => %{"in" => [%{"themeName" => "dark"}]}})
      assert error["type"] == "unknown_filter_operator"
    end

    test "a bare value on an embedded resource is unknown" do
      error = error("list_posts", %{"settings" => %{"themeName" => "dark"}})
      assert error["type"] == "unknown_filter_operator"
    end

    test "a calculation returning a resource takes isNil only" do
      assert %{"success" => true} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "filter" => %{"selfPost" => %{"isNil" => false}}
               })

      error = error("list_posts", %{"selfPost" => %{"eq" => %{"title" => "x"}}})
      assert error["type"] == "unknown_filter_operator"
    end
  end

  describe "scalars are unchanged" do
    test "eq on a string keeps its value as sent" do
      Ash.create!(Post, %{title: "Alpha"})

      assert %{"success" => true, "data" => [%{"title" => "Alpha"}]} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "filter" => %{"title" => %{"eq" => "Alpha"}, "viewCount" => %{"lessThan" => 100}}
               })
    end
  end
end
