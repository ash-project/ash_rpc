# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.RunActionTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  test "create then list through the wire contract" do
    assert %{"success" => true, "data" => %{"title" => "Hello"}} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "create_post",
               "input" => %{"title" => "Hello"},
               "fields" => ["title"]
             })

    assert %{"success" => true, "data" => [%{"title" => "Hello"}]} =
             AshRpc.run_action(@profile, ctx(), %{"action" => "list_posts", "fields" => ["title"]})
  end

  test "argument overrides apply to input" do
    assert %{"success" => true, "data" => 2} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "word_count",
               "input" => %{"body" => "two words"}
             })
  end

  test "a bad argument cast on a generic action is invalid_argument" do
    # `fields` is the internal name: error fields get resource field-name
    # overrides only, not argument_names overrides (`body` on the wire).
    assert %{
             "success" => false,
             "errors" => [%{"type" => "invalid_argument", "fields" => ["text"]}]
           } =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "word_count",
               "input" => %{"body" => %{"not" => "a string"}}
             })
  end

  test "unknown action and missing action" do
    assert %{"success" => false, "errors" => [%{"type" => "action_not_found"}]} =
             AshRpc.run_action(@profile, ctx(), %{"action" => "nope"})

    assert %{"success" => false, "errors" => [%{"type" => "missing_required_parameter"}]} =
             AshRpc.run_action(@profile, ctx(), %{})
  end

  describe "exceptions raised while handling a request" do
    import ExUnit.CaptureLog

    # A non-string `action` raises inside parse_request; any raise works here.
    test "run_action logs them with a stacktrace and returns unknown_error" do
      {response, log} =
        with_log(fn -> AshRpc.run_action(@profile, ctx(), %{"action" => 123}) end)

      assert %{"success" => false, "errors" => [%{"type" => "unknown_error"}]} = response
      assert log =~ "CaseClauseError"
      assert log =~ "lib/ash_rpc/pipeline.ex"
    end

    test "validate_action logs them with a stacktrace and returns unknown_error" do
      {response, log} =
        with_log(fn -> AshRpc.validate_action(@profile, ctx(), %{"action" => 123}) end)

      assert %{"success" => false, "errors" => [%{"type" => "unknown_error"}]} = response
      assert log =~ "CaseClauseError"
      assert log =~ "lib/ash_rpc/pipeline.ex"
    end
  end

  test "manifest: option changes output casing" do
    manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)

    assert %{"Success" => true, "Data" => %{"ViewCount" => 0}} =
             AshRpc.run_action(
               @profile,
               ctx(),
               %{
                 "action" => "create_post",
                 "input" => %{"title" => "x"},
                 "fields" => ["viewCount"]
               },
               manifest: manifest
             )
  end

  test "update returns only the selected fields and loads relationships" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Old", view_count: 3, author_id: author.id})

    assert %{"success" => true, "data" => data} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "update_post",
               "identity" => post.id,
               "input" => %{"title" => "New"},
               "fields" => ["title", %{"author" => ["name"]}]
             })

    assert data == %{"title" => "New", "author" => %{"name" => "Ada"}}
  end

  test "destroy returns only the selected fields and loads relationships" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Gone", view_count: 3, author_id: author.id})

    assert %{"success" => true, "data" => data} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "destroy_post",
               "identity" => post.id,
               "fields" => ["title", %{"author" => ["name"]}]
             })

    assert data == %{"title" => "Gone", "author" => %{"name" => "Ada"}}
  end
end
