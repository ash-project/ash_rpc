# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.NestedQueryOptsTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Pipeline, ResultProcessor, Runtime}
  alias AshRpc.Test.{Comment, Post, PostTag, Tag}

  @profile AshRpc.Test.Profile

  @offset_page_keys ~w(count hasMore limit offset results type)
  @keyset_page_keys ~w(after before count hasMore limit nextPage previousPage results type)

  defp ctx, do: %AshRpc.Context{}

  # One post per test (ETS tables are per-process), with `comment_count` comments whose
  # bodies sort as "comment-1", "comment-2", ... and ratings 2, 3, 4, 5, 1, ...
  defp seed_post(comment_count) do
    post = Ash.create!(Post, %{title: "Nested"})

    for i <- 1..comment_count//1 do
      Ash.create!(Comment, %{body: "comment-#{i}", rating: rem(i, 5) + 1, post_id: post.id})
    end

    post
  end

  # Lists the single seeded post with `id` plus one nested field spec.
  defp list_post_with(nested_field) do
    assert %{"success" => true, "data" => [post]} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "list_posts",
               "fields" => ["id", nested_field]
             })

    post
  end

  defp parse(params), do: Pipeline.parse_request(Runtime.new(@profile), ctx(), params)

  defp comment(attrs, cursor) do
    Comment
    |> struct(attrs)
    |> Map.put(:__metadata__, %{keyset: cursor})
  end

  defp keyset_page(results) do
    struct(Ash.Page.Keyset, %{
      results: results,
      limit: 2,
      before: nil,
      after: nil,
      count: nil,
      more?: false
    })
  end

  describe "nested offset pages" do
    test "a paged has_many returns the top-level offset page shape" do
      seed_post(5)

      post =
        list_post_with(%{
          "comments" => %{
            "page" => %{"limit" => 2, "offset" => 0, "count" => true},
            "sort" => "body",
            "fields" => ["id", "body"]
          }
        })

      page = post["comments"]
      assert Enum.sort(Map.keys(page)) == @offset_page_keys
      assert page["type"] == :offset
      assert page["limit"] == 2
      assert page["offset"] == 0
      assert page["hasMore"] == true
      assert page["count"] == 5
      assert [%{"body" => "comment-1"}, %{"body" => "comment-2"}] = page["results"]
    end

    test "a bare page limit on a mixed-pagination read follows Ash's default page type" do
      seed_post(2)

      post =
        list_post_with(%{
          "comments" => %{"page" => %{"limit" => 5}, "sort" => "body", "fields" => ["id"]}
        })

      page = post["comments"]
      # Ash picks `:default_page_type` (default :offset) when a read allows both
      # offset and keyset and no offset/after/before is given; ash_rpc's config leaves
      # it unset. The source suite configures :keyset, hence its keyset assertion.
      assert page["type"] == :offset
      assert page["offset"] == 0
      assert page["count"] == nil
      assert length(page["results"]) == 2
    end

    test "an offset-only relationship pages with its own read action" do
      seed_post(3)

      post =
        list_post_with(%{
          "commentsOffset" => %{
            "page" => %{"limit" => 2, "offset" => 0, "count" => true},
            "fields" => ["id"]
          }
        })

      page = post["commentsOffset"]
      assert page["type"] == :offset
      assert page["count"] == 3
      assert page["hasMore"] == true
      assert length(page["results"]) == 2
    end
  end

  describe "nested keyset pages" do
    test "a keyset-only relationship returns the keyset page shape with cursors" do
      seed_post(3)

      post =
        list_post_with(%{
          "commentsKeyset" => %{
            "page" => %{"limit" => 2},
            "sort" => "body",
            "fields" => ["id", "body"]
          }
        })

      page = post["commentsKeyset"]
      assert Enum.sort(Map.keys(page)) == @keyset_page_keys
      assert page["type"] == :keyset
      assert [%{"body" => "comment-1"}, %{"body" => "comment-2"}] = page["results"]
      assert is_binary(page["previousPage"])
      assert is_binary(page["nextPage"])
    end

    test "an empty keyset page past the last cursor has nil cursors" do
      seed_post(2)

      envelope = fn page ->
        %{"commentsKeyset" => %{"page" => page, "sort" => "body", "fields" => ["id"]}}
      end

      first = list_post_with(envelope.(%{"limit" => 5}))["commentsKeyset"]
      assert length(first["results"]) == 2
      assert is_binary(first["nextPage"])

      empty =
        list_post_with(envelope.(%{"limit" => 5, "after" => first["nextPage"]}))[
          "commentsKeyset"
        ]

      assert %{"type" => :keyset, "results" => [], "previousPage" => nil, "nextPage" => nil} =
               empty
    end
  end

  describe "unpaged envelopes" do
    test "filter, sort and limit without page keep the plain array shape" do
      seed_post(5)

      post =
        list_post_with(%{
          "comments" => %{
            "filter" => %{"rating" => %{"greaterThan" => 2}},
            "sort" => "-rating",
            "limit" => 2,
            "fields" => ["id", "rating"]
          }
        })

      assert [%{"rating" => 5}, %{"rating" => 4}] = post["comments"]
    end

    test "an envelope on a create result is accepted" do
      assert %{"success" => true, "data" => data} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "create_post",
                 "input" => %{"title" => "With comments"},
                 "fields" => ["id", %{"comments" => %{"limit" => 1, "fields" => ["id"]}}]
               })

      assert is_binary(data["id"])
      assert data["comments"] == []
    end
  end

  describe "many_to_many envelopes" do
    setup do
      post = seed_post(0)

      for name <- ["beta", "alpha"] do
        tag = Ash.create!(Tag, %{name: name})
        Ash.create!(PostTag, %{post_id: post.id, tag_id: tag.id})
      end

      :ok
    end

    test "a sorted, limited many_to_many loads through the join resource" do
      post =
        list_post_with(%{
          "tags" => %{"sort" => "name", "limit" => 1, "fields" => ["id", "name"]}
        })

      assert [%{"name" => "alpha"}] = post["tags"]
    end

    test "a paged many_to_many returns the offset page shape" do
      post =
        list_post_with(%{
          "tags" => %{
            "page" => %{"limit" => 1, "offset" => 0},
            "sort" => "name",
            "fields" => ["name"]
          }
        })

      page = post["tags"]
      assert page["type"] == :offset
      assert [%{"name" => "alpha"}] = page["results"]
      # Ash fetches limit + 1 for related pages, so `more?` is set on ETS.
      assert page["hasMore"] == true
    end
  end

  describe "entrypoint flags gate nested envelopes" do
    test "a nested filter under enable_filter?: false is disabled" do
      params = %{
        "action" => "list_posts_no_filter",
        "fields" => [
          "id",
          %{"comments" => %{"filter" => %{"rating" => %{"eq" => 1}}, "fields" => ["id"]}}
        ]
      }

      assert {:error, {:filter_not_supported, :comments, :disabled, []}} = parse(params)
    end

    test "a nested sort under enable_sort?: false is disabled" do
      params = %{
        "action" => "list_posts_no_sort",
        "fields" => ["id", %{"comments" => %{"sort" => "-rating", "fields" => ["id"]}}]
      }

      assert {:error, {:sort_not_supported, :comments, :disabled, []}} = parse(params)
    end

    test "a nested filter under a default entrypoint parses" do
      params = %{
        "action" => "list_posts",
        "fields" => [
          "id",
          %{"comments" => %{"filter" => %{"rating" => %{"eq" => 1}}, "fields" => ["id"]}}
        ]
      }

      assert {:ok, %AshRpc.Request{}} = parse(params)
    end
  end

  describe "top-level pagination" do
    test "a page on a paginated read returns the offset page shape" do
      seed_post(3)

      assert %{"success" => true, "data" => page} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_comments",
                 "fields" => ["body"],
                 "sort" => "body",
                 "page" => %{"limit" => 2, "offset" => 0, "count" => true}
               })

      assert Enum.sort(Map.keys(page)) == @offset_page_keys
      assert page["type"] == :offset
      assert page["count"] == 3
      assert page["hasMore"] == true
      assert [%{"body" => "comment-1"}, %{"body" => "comment-2"}] = page["results"]
    end

    test "an offset past the end returns an empty page" do
      seed_post(2)

      assert %{"success" => true, "data" => page} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_comments",
                 "fields" => ["body"],
                 "page" => %{"limit" => 10, "offset" => 100}
               })

      assert page["results"] == []
      assert page["hasMore"] == false
    end

    test "top-level limit/offset without page are ignored and return a plain list" do
      seed_post(3)

      assert %{"success" => true, "data" => comments} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_comments",
                 "fields" => ["body"],
                 "limit" => 1,
                 "offset" => 0
               })

      assert length(comments) == 3
    end

    test "an unknown page key is invalid_pagination on the page path" do
      params = %{
        "action" => "list_comments",
        "fields" => ["body"],
        "page" => %{"limit" => 10, "notAPageOptionXyz" => 1}
      }

      # The key is parsed to a string because no such atom exists.
      assert {:error, {:unknown_page_keys, ["not_a_page_option_xyz"]}} = parse(params)

      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), params)

      assert error["type"] == "invalid_pagination"
      assert error["vars"] == %{"keys" => "notAPageOptionXyz"}
      assert error["fields"] == ["notAPageOptionXyz"]
      assert error["path"] == ["page"]
    end
  end

  describe "ResultProcessor page maps" do
    test "build_page_map gives an empty Ash.Page.Keyset nil cursors" do
      post = Post |> struct(%{id: "p1"}) |> Map.put(:comments, keyset_page([]))

      result =
        ResultProcessor.process(
          post,
          [:id, {:comments, [:id]}],
          Post,
          Runtime.new(@profile)
        )

      assert result.comments == %{
               type: :keyset,
               results: [],
               previous_page: nil,
               next_page: nil,
               has_more: false,
               before: nil,
               after: nil,
               limit: 2,
               count: nil
             }
    end

    test "a non-empty nested keyset page takes cursors from the first and last record" do
      results = [
        comment(%{id: "c1", body: "a"}, "cursor-first"),
        comment(%{id: "c2", body: "b"}, "cursor-last")
      ]

      post = Post |> struct(%{id: "p1"}) |> Map.put(:comments, keyset_page(results))

      result =
        ResultProcessor.process(
          post,
          [:id, {:comments, [:id]}],
          Post,
          Runtime.new(@profile)
        )

      assert result.comments.previous_page == "cursor-first"
      assert result.comments.next_page == "cursor-last"
      assert result.comments.results == [%{id: "c1"}, %{id: "c2"}]
    end
  end
end
