# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.CalculationsTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp list_posts(fields), do: run(%{"action" => "list_posts", "fields" => fields})

  defp parse(params),
    do: AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)

  defp single_error(%{"success" => false, "errors" => [error]}), do: error

  # One author with one post titled "Hello world" (view_count 3).
  defp seed_post do
    name = "Ada-#{System.unique_integer([:positive])}"
    author = Ash.create!(AshRpc.Test.Author, %{name: name})

    post =
      Ash.create!(AshRpc.Test.Post, %{
        title: "Hello world",
        view_count: 3,
        author_id: author.id
      })

    %{author: author, post: post}
  end

  describe "selecting calculations" do
    setup do
      seed_post()
    end

    test "a calculation without arguments is selected by name", %{post: post} do
      assert %{"success" => true, "data" => [row]} = list_posts(["id", "titleLength"])
      assert row == %{"id" => post.id, "titleLength" => 11}
    end

    test "a scalar calculation with arguments takes args only" do
      assert %{"success" => true, "data" => [row]} =
               list_posts([%{"excerpt" => %{"args" => %{"length" => 5}}}])

      assert row == %{"excerpt" => "Hello"}
    end

    test "a typed-map calculation takes args and fields; unselected keys are absent" do
      assert %{"success" => true, "data" => [row]} =
               list_posts([
                 %{"scoredStats" => %{"args" => %{"boost" => 2}, "fields" => ["wordCount1"]}}
               ])

      # `view_count` 3 + boost 2; isFeatured not selected, so not emitted
      assert row == %{"scoredStats" => %{"wordCount1" => 5}}
    end

    test "a resource-returning calculation nests relationships", %{author: author} do
      assert %{"success" => true, "data" => [row]} =
               list_posts(["title", %{"selfPost" => ["title", %{"author" => ["name"]}]}])

      # Load-through of {self_post, {%{}, [:title, author: [:name]]}} on ETS
      assert row == %{
               "title" => "Hello world",
               "selfPost" => %{"title" => "Hello world", "author" => %{"name" => author.name}}
             }
    end

    test "calculations mix with attributes, relationships and nested calculations", %{
      author: author,
      post: post
    } do
      assert %{"success" => true, "data" => [row]} =
               list_posts([
                 "id",
                 "title",
                 "titleLength",
                 %{"excerpt" => %{"args" => %{"length" => 5}}},
                 %{"author" => ["name", "isProlific"]}
               ])

      assert row == %{
               "id" => post.id,
               "title" => "Hello world",
               "titleLength" => 11,
               "excerpt" => "Hello",
               "author" => %{"name" => author.name, "isProlific" => false}
             }
    end
  end

  describe "requires_field_selection" do
    test "a complex calculation requested as a bare name" do
      assert %{"type" => "requires_field_selection", "fields" => ["selfPost"], "path" => []} =
               single_error(list_posts(["id", "selfPost"]))
    end

    test "a complex calculation with args but missing or empty fields" do
      missing = %{"scoredStats" => %{"args" => %{"boost" => 1}}}
      empty = %{"scoredStats" => %{"args" => %{"boost" => 1}, "fields" => []}}

      for selection <- [missing, empty] do
        assert %{"type" => "requires_field_selection", "fields" => ["scoredStats"]} =
                 single_error(list_posts([selection]))
      end
    end
  end

  describe "invalid_calculation_args" do
    test "args on a calculation that takes none" do
      assert %{"type" => "invalid_calculation_args", "fields" => ["titleLength"]} =
               single_error(list_posts([%{"titleLength" => %{"args" => %{}}}]))
    end

    test "missing args on a calculation that takes arguments" do
      assert %{"type" => "invalid_calculation_args", "fields" => ["scoredStats"]} =
               single_error(list_posts([%{"scoredStats" => %{"fields" => ["wordCount1"]}}]))
    end

    test "an args key the calculation doesn't define fails when Ash builds the load" do
      seed_post()

      # Arg keys reach Ash as strings. A key naming an existing atom is
      # Ash.Error.Invalid.NoSuchInput, which has no AshRpc.Error impl.
      assert %{"type" => "internal_error", "path" => ["load"]} =
               single_error(list_posts([%{"excerpt" => %{"args" => %{"title" => 1}}}]))

      # A key naming no existing atom fails atom conversion instead.
      unknown_key = "no_such_arg_#{System.unique_integer([:positive])}"

      assert %{"type" => "unknown_error", "path" => ["load"]} =
               single_error(list_posts([%{"excerpt" => %{"args" => %{unknown_key => 1}}}]))
    end
  end

  test "calculation_requires_args: a calculation with arguments requested as a bare name" do
    params = %{"action" => "list_posts", "fields" => ["id", "excerpt"]}

    assert {:error, {:calculation_requires_args, :excerpt, []}} = parse(params)

    # The wire type for this tuple is invalid_field_format (see ErrorBuilder).
    assert %{
             "type" => "invalid_field_format",
             "fields" => ["excerpt"],
             "vars" => %{"field" => "excerpt"}
           } = single_error(run(params))
  end

  test "invalid_field_selection: a fields key on a scalar calculation" do
    selection = %{"excerpt" => %{"args" => %{"length" => 3}, "fields" => []}}

    assert %{"type" => "invalid_field_selection", "fields" => ["excerpt"]} =
             single_error(list_posts([selection]))
  end

  test "field_does_not_support_nesting: nested fields on a scalar calculation" do
    assert %{
             "type" => "field_does_not_support_nesting",
             "fields" => ["titleLength"],
             "path" => []
           } = single_error(list_posts([%{"titleLength" => ["x"]}]))
  end

  describe "unknown_field" do
    test "an unknown calculation name" do
      selection = %{"nonExistentCalc" => %{"args" => %{}, "fields" => ["id"]}}

      assert %{"type" => "unknown_field", "fields" => ["nonExistentCalc"]} =
               single_error(list_posts([selection]))
    end

    test "an unknown field inside a calculation's selection" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["selfPost.nope"],
               "path" => ["selfPost"]
             } = single_error(list_posts([%{"selfPost" => ["nope"]}]))

      selection = %{"scoredStats" => %{"args" => %{"boost" => 1}, "fields" => ["nope"]}}

      # PostStats has field-name overrides, so it is a typed struct
      # (unknown_field with kind "field constrained"), not a plain typed map.
      assert %{
               "type" => "unknown_field",
               "fields" => ["scoredStats.nope"],
               "path" => ["scoredStats"],
               "vars" => %{"kind" => "field constrained"}
             } = single_error(list_posts([selection]))
    end
  end

  # A typed map without field-name overrides reports unknown_map_field. Field
  # selection dispatches on the return type, so the `totals` action's typed-map
  # return exercises the same branch a map-returning calculation would.
  test "unknown_map_field: an unknown key in a typed-map return" do
    assert %{
             "type" => "unknown_map_field",
             "fields" => ["nope"],
             "path" => []
           } = single_error(run(%{"action" => "totals", "fields" => ["nope"]}))
  end

  test "duplicate_field: the same calculation requested twice with different args" do
    params = %{
      "action" => "list_posts",
      "fields" => [
        %{"excerpt" => %{"args" => %{"length" => 1}}},
        %{"excerpt" => %{"args" => %{"length" => 2}}}
      ]
    }

    assert {:error, {:duplicate_field, :excerpt, []}} = parse(params)

    assert %{"type" => "duplicate_field", "fields" => ["excerpt"]} =
             single_error(run(params))
  end
end
