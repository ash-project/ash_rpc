# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.LoadRestrictionsTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp parse(params) do
    AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)
  end

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp seed! do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Hello", author_id: author.id})
    comment = Ash.create!(AshRpc.Test.Comment, %{body: "Nice", rating: 3, post_id: post.id})
    %{author: author, post: post, comment: comment}
  end

  describe "allow list" do
    test "a listed relationship loads" do
      seed!()

      assert %{"success" => true, "data" => [post]} =
               run(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["title", %{"author" => ["name"]}]
               })

      assert post == %{"title" => "Hello", "author" => %{"name" => "Ada"}}
    end

    test "an unlisted relationship is load_not_allowed" do
      assert {:error, {:load_not_allowed, ["comments"]}} =
               parse(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["id", %{"comments" => ["id"]}]
               })
    end

    test "top-level calculations and aggregates count as loads" do
      assert {:error, {:load_not_allowed, ["title_length"]}} =
               parse(%{"action" => "list_posts_allow_author", "fields" => ["id", "titleLength"]})

      assert {:error, {:load_not_allowed, ["comment_count"]}} =
               parse(%{"action" => "list_posts_allow_author", "fields" => ["id", "commentCount"]})
    end

    test "an explicitly allowed nested path loads" do
      seed!()

      params = %{
        "action" => "list_posts_allow_nested",
        "fields" => ["title", %{"comments" => ["body", %{"post" => ["title"]}]}]
      }

      assert {:ok, request} = parse(params)
      assert request.load == [{:comments, [:body, {:post, [:title]}]}]

      assert %{"success" => true, "data" => [post]} = run(params)

      assert post == %{
               "title" => "Hello",
               "comments" => [%{"body" => "Nice", "post" => %{"title" => "Hello"}}]
             }
    end

    test "an intermediate relationship of an allowed nested path loads" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts_allow_nested",
                 "fields" => ["id", %{"comments" => ["id", "body"]}]
               })

      assert request.load == [{:comments, [:id, :body]}]
    end

    test "a child of an allowed relationship is not implicitly allowed" do
      assert {:error, {:load_not_allowed, ["author.posts"]}} =
               parse(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["id", %{"author" => ["id", %{"posts" => ["id"]}]}]
               })
    end

    test "a relationship outside an allowed nested path is load_not_allowed" do
      assert {:error, {:load_not_allowed, ["author"]}} =
               parse(%{
                 "action" => "list_posts_allow_nested",
                 "fields" => ["id", %{"author" => ["id"]}]
               })
    end

    test "a request with no loads passes" do
      assert {:ok, request} =
               parse(%{"action" => "list_posts_allow_author", "fields" => ["id", "title"]})

      assert request.load == []
    end
  end

  describe "deny list" do
    test "an unlisted relationship loads" do
      seed!()

      assert %{"success" => true, "data" => [post]} =
               run(%{
                 "action" => "list_posts_deny_author",
                 "fields" => ["title", %{"comments" => ["body"]}]
               })

      assert post == %{"title" => "Hello", "comments" => [%{"body" => "Nice"}]}
    end

    test "a denied relationship is load_denied" do
      assert {:error, {:load_denied, ["author"]}} =
               parse(%{
                 "action" => "list_posts_deny_author",
                 "fields" => ["id", %{"author" => ["id"]}]
               })
    end

    test "children of a denied relationship are denied" do
      # The nested path is checked before its parent, so the child path is reported
      assert {:error, {:load_denied, ["author.posts"]}} =
               parse(%{
                 "action" => "list_posts_deny_author",
                 "fields" => ["id", %{"author" => ["id", %{"posts" => ["id"]}]}]
               })
    end

    test "a nested deny leaves the parent loadable" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => ["id", %{"comments" => ["id", "body"]}]
               })

      assert request.load == [{:comments, [:id, :body]}]
    end

    test "a denied nested path is load_denied" do
      assert {:error, {:load_denied, ["comments.post"]}} =
               parse(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => ["id", %{"comments" => ["id", %{"post" => ["id"]}]}]
               })
    end

    test "a request with no loads passes" do
      assert {:ok, request} =
               parse(%{"action" => "list_posts_deny_author", "fields" => ["id", "title"]})

      assert request.load == []
    end
  end

  describe "wire errors" do
    test "load_not_allowed carries the disallowed paths" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["id", %{"comments" => ["id"]}]
               })

      assert %{
               "type" => "load_not_allowed",
               "shortMessage" => "Load not allowed",
               "fields" => ["comments"],
               "path" => [],
               "vars" => %{"fields" => "comments"},
               "details" => %{"disallowedPaths" => ["comments"]}
             } = error
    end

    test "load_denied carries the denied paths" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "list_posts_deny_author",
                 "fields" => ["id", %{"author" => ["id"]}]
               })

      assert %{
               "type" => "load_denied",
               "shortMessage" => "Load denied",
               "fields" => ["author"],
               "path" => [],
               "vars" => %{"fields" => "author"},
               "details" => %{"deniedPaths" => ["author"]}
             } = error
    end
  end

  describe "nested calculations" do
    test "a calculation on an allowed relationship is load_not_allowed" do
      assert {:error, {:load_not_allowed, ["author.is_prolific?"]}} =
               parse(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["id", %{"author" => ["id", "isProlific"]}]
               })
    end

    test "an explicitly allowed nested calculation loads" do
      %{author: author} = seed!()
      Ash.create!(AshRpc.Test.Post, %{title: "Second", author_id: author.id})

      params = %{
        "action" => "list_posts_allow_nested_calc",
        "fields" => ["title", %{"author" => ["name", "isProlific"]}]
      }

      assert {:ok, request} = parse(params)
      assert request.load == [{:author, [:name, :is_prolific?]}]

      assert %{"success" => true, "data" => posts} = run(params)
      assert length(posts) == 2
      assert Enum.all?(posts, &(&1["author"] == %{"name" => "Ada", "isProlific" => true}))
    end

    test "allowing one nested calculation does not allow a sibling aggregate" do
      assert {:error, {:load_not_allowed, ["author.post_count"]}} =
               parse(%{
                 "action" => "list_posts_allow_nested_calc",
                 "fields" => ["id", %{"author" => ["id", "postCount"]}]
               })
    end

    test "a denied nested calculation is load_denied" do
      assert {:error, {:load_denied, ["author.is_prolific?"]}} =
               parse(%{
                 "action" => "list_posts_deny_nested_calc",
                 "fields" => ["id", %{"author" => ["id", "isProlific"]}]
               })
    end

    test "attributes beside a denied nested calculation load" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts_deny_nested_calc",
                 "fields" => ["id", %{"author" => ["id", "name"]}]
               })

      assert request.load == [{:author, [:id, :name]}]
    end

    test "a nested calculation outside a nested deny loads" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => ["id", %{"comments" => ["id", "weightedRating"]}]
               })

      assert request.load == [{:comments, [:id, :weighted_rating]}]
    end

    test "an embedded resource calculation is a load" do
      fields = ["id", %{"settings" => ["themeName", "themeLabel"]}]

      assert {:error, {:load_not_allowed, ["settings.theme_label"]}} =
               parse(%{"action" => "list_posts_allow_author", "fields" => fields})

      assert {:ok, request} = parse(%{"action" => "list_posts_deny_author", "fields" => fields})
      assert request.load == [{:settings, [:theme_label]}]
    end

    test "a union member calculation is a load" do
      assert {:error, {:load_not_allowed, ["attachment.file.label"]}} =
               parse(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["id", %{"attachment" => [%{"file" => ["url", "label"]}]}]
               })

      assert {:ok, request} =
               parse(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["id", %{"attachment" => [%{"file" => ["url"]}]}]
               })

      assert request.load == []
    end

    test "a union member calculation is a load with and without an envelope" do
      attachment = %{"attachment" => [%{"file" => ["label"]}]}

      plain = %{
        "action" => "list_posts_allow_nested",
        "fields" => ["id", %{"comments" => ["id", attachment]}]
      }

      envelope = %{
        "action" => "list_posts_allow_nested",
        "fields" => ["id", %{"comments" => %{"fields" => ["id", attachment]}}]
      }

      assert {:error, {:load_not_allowed, ["comments.attachment.file.label"]}} = parse(plain)
      assert {:error, {:load_not_allowed, ["comments.attachment.file.label"]}} = parse(envelope)
    end

    test "a calculation inside a limit envelope is a load" do
      assert {:error, {:load_not_allowed, ["comments.weighted_rating"]}} =
               parse(%{
                 "action" => "list_posts_allow_nested",
                 "fields" => [
                   "id",
                   %{"comments" => %{"limit" => 2, "fields" => ["id", "weightedRating"]}}
                 ]
               })
    end
  end

  describe "query envelopes" do
    test "a denied path inside an envelope is load_denied" do
      assert {:error, {:load_denied, ["comments.post"]}} =
               parse(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => [
                   "id",
                   %{"comments" => %{"limit" => 2, "fields" => ["id", %{"post" => ["id"]}]}}
                 ]
               })
    end

    test "an allowed envelope load passes" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts_allow_nested",
                 "fields" => [
                   "id",
                   %{"comments" => %{"limit" => 2, "fields" => ["id", %{"post" => ["id"]}]}}
                 ]
               })

      assert [{:comments, %Ash.Query{}}] = request.load
    end

    test "an envelope on an unlisted relationship is load_not_allowed" do
      assert {:error, {:load_not_allowed, ["comments"]}} =
               parse(%{
                 "action" => "list_posts_allow_author",
                 "fields" => ["id", %{"comments" => %{"limit" => 2, "fields" => ["id"]}}]
               })
    end

    test "a denied path inside a paged envelope fails on the wire" do
      seed!()

      assert %{
               "success" => false,
               "errors" => [%{"type" => "load_denied", "fields" => ["comments.post"]}]
             } =
               run(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => [
                   "id",
                   %{
                     "comments" => %{
                       "page" => %{"limit" => 2},
                       "fields" => ["id", %{"post" => ["id"]}]
                     }
                   }
                 ]
               })
    end
  end

  describe "pagination" do
    test "an offset page keeps the allow list" do
      seed!()

      assert %{"success" => true, "data" => page} =
               run(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["body", %{"post" => ["title"]}],
                 "page" => %{"offset" => 0, "limit" => 10}
               })

      assert %{
               "results" => [%{"body" => "Nice", "post" => %{"title" => "Hello"}}],
               "hasMore" => false
             } = page

      assert %{
               "success" => false,
               "errors" => [%{"type" => "load_not_allowed", "fields" => ["weighted_rating"]}]
             } =
               run(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["body", "weightedRating"],
                 "page" => %{"offset" => 0, "limit" => 10}
               })
    end

    test "a keyset page keeps the allow list" do
      seed!()

      assert %{"success" => true, "data" => page} =
               run(%{
                 "action" => "list_comments_keyset_allow_post",
                 "fields" => ["body", %{"post" => ["title"]}],
                 "page" => %{"limit" => 10}
               })

      assert %{"results" => [%{"body" => "Nice", "post" => %{"title" => "Hello"}}]} = page
      # The keyset-only read makes a bare limit a keyset page (the mixed read defaults to offset).
      assert Map.has_key?(page, "nextPage")

      assert %{"success" => false, "errors" => [%{"type" => "load_not_allowed"}]} =
               run(%{
                 "action" => "list_comments_keyset_allow_post",
                 "fields" => ["body", "weightedRating"],
                 "page" => %{"limit" => 10}
               })
    end

    test "count: true keeps the allow list" do
      seed!()

      assert %{"success" => true, "data" => page} =
               run(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["body", %{"post" => ["title"]}],
                 "page" => %{"offset" => 0, "limit" => 5, "count" => true}
               })

      assert %{"count" => 1, "results" => [%{"post" => %{"title" => "Hello"}}]} = page

      assert %{"success" => false, "errors" => [%{"type" => "load_not_allowed"}]} =
               run(%{
                 "action" => "list_comments_allow_post",
                 "fields" => ["body", "weightedRating"],
                 "page" => %{"offset" => 0, "limit" => 5, "count" => true}
               })
    end

    test "a deny list applies inside a nested offset page" do
      seed!()

      envelope = %{
        "page" => %{"offset" => 0, "limit" => 2},
        "fields" => ["id", %{"post" => ["id"]}]
      }

      assert %{"success" => false, "errors" => [%{"type" => "load_denied"}]} =
               run(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => ["id", %{"comments" => envelope}]
               })
    end

    test "count: true in a nested page with permitted fields succeeds" do
      seed!()

      assert %{"success" => true, "data" => [post]} =
               run(%{
                 "action" => "list_posts_deny_nested",
                 "fields" => [
                   "title",
                   %{
                     "comments" => %{
                       "page" => %{"offset" => 0, "limit" => 2, "count" => true},
                       "fields" => ["body"]
                     }
                   }
                 ]
               })

      # Nested offset page map carries count and results under the camelCase keys
      assert %{"count" => 1, "results" => [%{"body" => "Nice"}]} = post["comments"]
    end
  end
end
