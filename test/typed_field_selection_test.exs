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

  describe "custom types" do
    # Palette is a hand-rolled Ash.Type with map storage and declared fields:
    # it is selected by sub-field, like a typed map.
    setup do
      %{rt: AshRpc.Runtime.new(AshRpc.Test.Profile)}
    end

    test "a bare declared custom-type field is requires_field_selection" do
      assert %{
               "success" => false,
               "errors" => [%{"type" => "requires_field_selection", "fields" => ["palette"]}]
             } = run("list_projects", ["id", "palette"])
    end

    test "selected sub-fields come back under client names" do
      assert %{"success" => true, "data" => data} =
               AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
                 "action" => "create_project",
                 "input" => %{
                   "palette" => %{
                     "primary" => "red",
                     "secondary" => "blue",
                     "accentColor" => "teal"
                   }
                 },
                 "fields" => [%{"palette" => ["primary", "accentColor"]}]
               })

      assert data["palette"] == %{"primary" => "red", "accentColor" => "teal"}
    end

    test "a sub-field selection goes to select and a nested template", %{rt: rt} do
      assert {:ok, {[:id, :palette], [], [:id, {:palette, [:primary]}]}} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, [
                 "id",
                 %{"palette" => ["primary"]}
               ])
    end

    test "sub-field selection at the top level succeeds" do
      assert %{"success" => true} =
               run("list_projects", [%{"palette" => ["primary", "secondary"]}])
    end

    test "nesting under a member is rejected as for typed maps" do
      # A map spec is a query envelope, as on Project's typed-struct `stats`.
      assert %{
               "success" => false,
               "errors" => [%{"type" => "unsupported_field_combination", "fields" => ["palette"]}]
             } = run("list_projects", [%{"palette" => %{"primary" => ["invalid"]}}])

      assert %{"success" => false, "errors" => [%{"type" => "invalid_field_selection"}]} =
               run("list_projects", [%{"palette" => [%{"primary" => ["invalid"]}]}])
    end

    test "sub-field selection through relationships succeeds", %{rt: rt} do
      fields = [%{"notes" => ["id", %{"project" => ["id", %{"palette" => ["primary"]}]}]}]

      assert {:ok, _} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, fields)

      assert %{"success" => true} = run("list_projects", fields)
    end

    test "sub-field selection inside a calculation's fields succeeds", %{rt: rt} do
      fields = [
        %{
          "self" => %{
            "args" => %{"prefix" => "x"},
            "fields" => ["id", %{"palette" => ["primary"]}]
          }
        }
      ]

      assert {:ok, _} =
               AshRpc.RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, fields)

      assert %{"success" => true} = run("list_projects", fields)
    end

    test "requesting a custom-type field twice is duplicate_field" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "duplicate_field",
                   "fields" => ["palette"],
                   "path" => [],
                   "vars" => %{"field" => "palette"},
                   "details" => details
                 }
               ]
             } = run("list_projects", [%{"palette" => ["primary"]}, %{"palette" => ["primary"]}])

      refute Map.has_key?(details, "hint")

      assert %{
               "success" => false,
               "errors" => [%{"type" => "duplicate_field", "fields" => ["palette"]}]
             } = run("list_projects", ["palette", "palette"])
    end

    test "an unknown field next to a custom-type field is unknown_field" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unknown_field",
                   "fields" => ["nonExistent"],
                   "path" => [],
                   "vars" => %{
                     "field" => "nonExistent",
                     "resource" => "AshRpc.Test.Project"
                   }
                 }
               ]
             } = run("list_projects", ["id", %{"palette" => ["primary"]}, "nonExistent"])
    end
  end
end
