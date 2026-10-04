# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.TypedFieldSelectionTest do
  use ExUnit.Case, async: true

  defp run(action, fields) do
    AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
      "action" => action,
      "fields" => fields
    })
  end

  defp error_type(%{"success" => false, "errors" => [%{"type" => type}]}), do: type

  test "sanity: typed returns select fields" do
    assert %{"success" => true, "data" => %{"wordCount1" => 3}} =
             run("stats_summary", ["wordCount1"])

    assert %{"success" => true, "data" => %{"total" => 2}} = run("totals", ["total"])
    assert %{"success" => true, "data" => %{"lat" => 1.0}} = run("location", ["lat"])
  end

  describe "query options on typed fields are rejected, not crashed on" do
    test "typed struct (type with field-name overrides)" do
      assert error_type(run("stats_summary", [%{"wordCount1" => %{"limit" => 1}}])) ==
               "invalid_query_opts"
    end

    test "typed map" do
      assert error_type(run("totals", [%{"byKind" => %{"limit" => 1, "fields" => ["drafts"]}}])) ==
               "invalid_query_opts"
    end

    test "tuple" do
      assert error_type(run("location", [%{"lat" => %{"limit" => 1}}])) == "invalid_query_opts"
    end

    test "union" do
      assert error_type(
               run("payload", [%{"stats" => %{"limit" => 1, "fields" => ["wordCount1"]}}])
             ) ==
               "invalid_query_opts"
    end
  end

  # Called below the pipeline: generic param parsing would turn the override
  # key "isFeatured" into :is_featured before type-aware translation.
  test "typed struct accepts several fields in one map" do
    rt = AshRpc.Runtime.new(AshRpc.Test.Profile)
    fields = [%{"wordCount1" => [], "isFeatured" => []}]

    assert {:ok, {[], [], template}} =
             AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :stats_summary, fields)

    assert Enum.sort(template) == [is_featured?: [], word_count_1: []]
  end

  test "string fields on an action without a return value do not crash" do
    # run_action rescues exceptions, so a crash shows up as unknown_error.
    refute match?(%{"errors" => [%{"type" => "unknown_error"}]}, run("ping", ["anything"]))
  end

  describe "templates key nested typed fields by internal name" do
    setup do
      %{rt: AshRpc.Runtime.new(AshRpc.Test.Profile)}
    end

    test "tuple", %{rt: rt} do
      assert {:ok, {[], [], [lat: []]}} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :location, [
                 %{"lat" => []}
               ])
    end

    test "union", %{rt: rt} do
      assert {:ok, {[], [], [stats: [:word_count_1]]}} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :payload, [
                 %{"stats" => ["wordCount1"]}
               ])
    end
  end

  describe "embedded resources" do
    test "nested fields select attributes and load calculations" do
      assert %{
               "success" => true,
               "data" => %{"settings" => settings}
             } =
               AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
                 "action" => "create_post",
                 "input" => %{"title" => "Embedded", "settings" => %{"themeName" => "dark"}},
                 "fields" => [%{"settings" => ["themeName", "themeLabel"]}]
               })

      assert settings == %{"themeName" => "dark", "themeLabel" => "theme:dark"}
    end

    test "a bare embedded field is requires_field_selection" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "requires_field_selection",
                   "fields" => ["settings"],
                   "vars" => %{"fieldType" => "Embedded_resource"}
                 }
               ]
             } = run("list_posts", ["settings"])
    end
  end

  describe "requires_field_selection on typed values" do
    test "top-level typed return keeps the pathless wire shape" do
      rt = AshRpc.Runtime.new(AshRpc.Test.Profile)

      assert {:error, {:requires_field_selection, :field_constrained_type, []}} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :totals, [])

      assert %{"success" => false, "errors" => [%{"fields" => [], "path" => []}]} =
               run("totals", [])
    end

    test "nested typed field reports which field needs a selection" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "requires_field_selection",
                   "fields" => ["byKind"],
                   "vars" => %{"field" => "byKind"}
                 }
               ]
             } = run("totals", [%{"byKind" => []}])
    end
  end
end
