# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.AggregatesTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  # Creates a post and one comment per entry in `comments` (maps of Comment attrs).
  defp seed_post(title, comments \\ [], attrs \\ %{}) do
    post = Ash.create!(AshRpc.Test.Post, Map.put(attrs, :title, title))

    for comment <- comments do
      Ash.create!(AshRpc.Test.Comment, Map.put(comment, :post_id, post.id))
    end

    post
  end

  # Three posts with 0, 1 and 2 comments; only the two-comment post has an
  # approved comment.
  defp seed_counted_posts do
    seed_post("zero")
    seed_post("one", [%{body: "only", rating: 1}])
    seed_post("two", [%{body: "x", rating: 5, approved: true}, %{body: "y", rating: 3}])
  end

  defp titles(%{"success" => true, "data" => data}),
    do: data |> Enum.map(& &1["title"]) |> Enum.sort()

  describe "aggregate values" do
    test "each Post aggregate is computed over its comments" do
      post =
        seed_post("Agg", [
          %{body: "b", rating: 4, approved: true},
          %{body: "a", rating: 2}
        ])

      assert %{"success" => true, "data" => [data]} =
               run(%{
                 "action" => "list_posts",
                 "fields" => [
                   "id",
                   "commentCount",
                   "approvedCommentCount",
                   "hasComments",
                   "avgRating",
                   "maxRating",
                   "firstCommentBody",
                   "commentBodies"
                 ]
               })

      assert data["id"] == post.id
      assert data["commentCount"] == 2
      assert data["approvedCommentCount"] == 1
      assert data["hasComments"] == true
      # Avg over integer ratings is returned as a float (3.0) on ETS
      assert data["avgRating"] == 3.0
      assert data["maxRating"] == 4
      assert data["firstCommentBody"] == "a"
      assert data["commentBodies"] == ["a", "b"]
    end

    test "Author.post_count counts the author's posts" do
      name = "author-#{System.unique_integer([:positive])}"
      author = Ash.create!(AshRpc.Test.Author, %{name: name})
      seed_post("p1", [], %{author_id: author.id})
      seed_post("p2", [], %{author_id: author.id})

      assert %{"success" => true, "data" => [%{"name" => ^name, "postCount" => 2}]} =
               run(%{"action" => "list_authors", "fields" => ["name", "postCount"]})
    end
  end

  describe "aggregates in mutation results" do
    test "create returns empty-aggregate values for a new post" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_post",
                 "input" => %{"title" => "Fresh"},
                 "fields" => [
                   "title",
                   "commentCount",
                   "hasComments",
                   "maxRating",
                   "firstCommentBody",
                   "commentBodies"
                 ]
               })

      assert data["title"] == "Fresh"
      assert data["commentCount"] == 0
      assert data["hasComments"] == false
      assert data["maxRating"] == nil
      assert data["firstCommentBody"] == nil
      # A list aggregate over no rows is [] (not nil) on ETS
      assert data["commentBodies"] == []
    end

    test "update returns aggregates reflecting existing comments" do
      post = seed_post("Old", [%{body: "c1", rating: 4}])

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "update_post",
                 "identity" => post.id,
                 "input" => %{"title" => "New"},
                 "fields" => ["id", "title", "commentCount", "commentBodies"]
               })

      assert data == %{
               "id" => post.id,
               "title" => "New",
               "commentCount" => 1,
               "commentBodies" => ["c1"]
             }
    end
  end

  describe "field selection errors" do
    test "nested selection on a primitive aggregate is invalid_field_selection" do
      for name <- ["commentCount", "hasComments", "commentBodies"] do
        assert %{"success" => false, "errors" => [error]} =
                 run(%{"action" => "list_posts", "fields" => [%{name => ["id"]}]})

        assert %{
                 "type" => "invalid_field_selection",
                 "vars" => %{"field" => ^name, "fieldType" => ":aggregate"},
                 "path" => [],
                 "fields" => [^name]
               } = error
      end
    end

    test "an unknown aggregate is unknown_field, bare or with nested fields" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{"action" => "list_posts", "fields" => ["id", "nopeCount"]})

      assert %{
               "type" => "unknown_field",
               "vars" => %{"field" => "nopeCount", "resource" => "AshRpc.Test.Post"},
               "fields" => ["nopeCount"]
             } = error

      assert %{"success" => false, "errors" => [%{"type" => "unknown_field"} = nested]} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["id", %{"latestComment" => ["id", "body"]}]
               })

      assert nested["fields"] == ["latestComment"]
    end
  end

  describe "sort and filter by aggregates" do
    test "sort by commentCount ascending and descending" do
      seed_counted_posts()

      assert %{"success" => true, "data" => asc} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title", "commentCount"],
                 "sort" => "commentCount"
               })

      assert Enum.map(asc, & &1["commentCount"]) == [0, 1, 2]

      assert %{"success" => true, "data" => desc} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title", "commentCount"],
                 "sort" => ["-commentCount", "title"]
               })

      assert Enum.map(desc, & &1["title"]) == ["two", "one", "zero"]
    end

    test "filter by a count aggregate" do
      seed_counted_posts()

      result =
        run(%{
          "action" => "list_posts",
          "fields" => ["title", "commentCount"],
          "filter" => %{"commentCount" => %{"greaterThan" => 1}}
        })

      assert titles(result) == ["two"]

      approved =
        run(%{
          "action" => "list_posts",
          "fields" => ["title"],
          "filter" => %{"approvedCommentCount" => %{"eq" => 1}}
        })

      assert titles(approved) == ["two"]
    end

    test "filter by an exists aggregate" do
      seed_counted_posts()

      with_comments =
        run(%{
          "action" => "list_posts",
          "fields" => ["title", "hasComments"],
          "filter" => %{"hasComments" => %{"eq" => true}}
        })

      assert titles(with_comments) == ["one", "two"]

      without =
        run(%{
          "action" => "list_posts",
          "fields" => ["title"],
          "filter" => %{"hasComments" => %{"eq" => false}}
        })

      assert titles(without) == ["zero"]
    end

    test "filter by a first aggregate with isNil" do
      seed_counted_posts()

      nil_first =
        run(%{
          "action" => "list_posts",
          "fields" => ["title", "firstCommentBody"],
          "filter" => %{"firstCommentBody" => %{"isNil" => true}}
        })

      assert %{"success" => true, "data" => [%{"firstCommentBody" => nil}]} = nil_first
      assert titles(nil_first) == ["zero"]

      present =
        run(%{
          "action" => "list_posts",
          "fields" => ["title"],
          "filter" => %{"firstCommentBody" => %{"isNil" => false}}
        })

      assert titles(present) == ["one", "two"]
    end
  end
end
