# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.NestedQueryOptsTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Pipeline, RequestedFieldsProcessor, ResultProcessor, Runtime}
  alias AshRpc.Test.{Author, Comment, Post, PostTag, Tag}

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

  defp process(resource, fields),
    do: RequestedFieldsProcessor.process(Runtime.new(@profile), resource, :read, fields)

  # Runs `action` with `id` plus one nested field spec and returns its single error.
  defp gate_error(action, nested_field, opts \\ []) do
    assert %{"success" => false, "errors" => [error]} =
             AshRpc.run_action(
               @profile,
               ctx(),
               %{"action" => action, "fields" => ["id", nested_field]},
               opts
             )

    error
  end

  defp wire_shape(error), do: Map.take(error, ~w(type fields path vars))

  defp hint, do: @profile.stale_client_hint()

  # The fixture manifest with Author.posts decorated as reading through an
  # unpaginated action.
  defp unpaginated_author_posts_manifest do
    manifest = AshRpc.Test.ManifestBuilder.build()

    resources =
      Enum.map(manifest.resources, fn
        %{module: Author} = resource ->
          update_in(
            resource.relationships[:posts].custom.ash_rpc,
            &Map.put(&1, :pagination, :none)
          )

        resource ->
          resource
      end)

    AshRpc.Manifest.put_lookups(%{manifest | resources: resources})
  end

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
      # it unset.
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

  describe "envelope gates" do
    test "an envelope on an attribute is invalid_query_opts naming the field kind" do
      error = gate_error("list_posts", %{"title" => %{"limit" => 1, "fields" => []}})

      assert wire_shape(error) == %{
               "type" => "invalid_query_opts",
               "fields" => ["title"],
               "path" => [],
               "vars" => %{"field" => "title", "kind" => "attribute"}
             }

      assert error["details"]["hint"] == hint()
    end

    test "an envelope on a to-one relationship is invalid_query_opts" do
      error = gate_error("list_posts", %{"author" => %{"limit" => 1, "fields" => ["id"]}})

      assert wire_shape(error) == %{
               "type" => "invalid_query_opts",
               "fields" => ["author"],
               "path" => [],
               "vars" => %{"field" => "author"}
             }

      assert error["details"]["hint"] == hint()
    end

    test "args combined with query options is invalid_query_opts without a hint" do
      error =
        gate_error("list_posts", %{
          "comments" => %{"args" => %{"x" => 1}, "limit" => 1, "fields" => ["id"]}
        })

      assert wire_shape(error) == %{
               "type" => "invalid_query_opts",
               "fields" => ["comments"],
               "path" => [],
               "vars" => %{"field" => "comments"}
             }

      assert error["details"] == %{
               "suggestion" => "Remove the args key — relationships do not take arguments"
             }
    end

    test "page on a relationship whose read action has no pagination is pagination_not_supported" do
      # Every to-many fixture relationship reads through a paginated action, so
      # the decoration of Author.posts is changed to an unpaginated read.
      manifest = unpaginated_author_posts_manifest()

      error =
        gate_error(
          "list_authors",
          %{"posts" => %{"page" => %{"limit" => 1}, "fields" => ["id"]}},
          manifest: manifest
        )

      assert wire_shape(error) == %{
               "type" => "pagination_not_supported",
               "fields" => ["posts"],
               "path" => [],
               "vars" => %{"field" => "posts"}
             }

      assert error["details"]["reason"] == :unsupported
      assert error["details"]["hint"] == hint()

      # Bare limit stays available on the same relationship.
      assert %{"success" => true, "data" => []} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "action" => "list_authors",
                   "fields" => ["id", %{"posts" => %{"limit" => 1, "fields" => ["id"]}}]
                 },
                 manifest: manifest
               )
    end

    test "filter on a relationship that is not filterable is filter_not_supported unsupported" do
      error =
        gate_error("list_posts", %{
          "unfilterableComments" => %{
            "filter" => %{"rating" => %{"eq" => 1}},
            "fields" => ["id"]
          }
        })

      assert wire_shape(error) == %{
               "type" => "filter_not_supported",
               "fields" => ["unfilterableComments"],
               "path" => [],
               "vars" => %{"field" => "unfilterableComments"}
             }

      assert error["details"]["reason"] == :unsupported
      assert error["details"]["hint"] == hint()
    end

    test "a nested filter under enable_filter?: false is filter_not_supported disabled" do
      nested = %{"comments" => %{"filter" => %{"rating" => %{"eq" => 1}}, "fields" => ["id"]}}

      assert {:error, {:filter_not_supported, :comments, :disabled, []}} =
               parse(%{"action" => "list_posts_no_filter", "fields" => ["id", nested]})

      error = gate_error("list_posts_no_filter", nested)

      assert wire_shape(error) == %{
               "type" => "filter_not_supported",
               "fields" => ["comments"],
               "path" => [],
               "vars" => %{"field" => "comments"}
             }

      assert error["details"]["reason"] == :disabled
    end

    test "sort on a relationship that is not sortable is sort_not_supported unsupported" do
      error =
        gate_error("list_posts", %{
          "unsortableComments" => %{"sort" => "-rating", "fields" => ["id"]}
        })

      assert wire_shape(error) == %{
               "type" => "sort_not_supported",
               "fields" => ["unsortableComments"],
               "path" => [],
               "vars" => %{"field" => "unsortableComments"}
             }

      assert error["details"]["reason"] == :unsupported
      assert error["details"]["hint"] == hint()
    end

    test "a nested sort under enable_sort?: false is sort_not_supported disabled" do
      nested = %{"comments" => %{"sort" => "-rating", "fields" => ["id"]}}

      assert {:error, {:sort_not_supported, :comments, :disabled, []}} =
               parse(%{"action" => "list_posts_no_sort", "fields" => ["id", nested]})

      error = gate_error("list_posts_no_sort", nested)

      assert wire_shape(error) == %{
               "type" => "sort_not_supported",
               "fields" => ["comments"],
               "path" => [],
               "vars" => %{"field" => "comments"}
             }

      assert error["details"]["reason"] == :disabled
    end

    test "page combined with bare limit or offset is invalid_query_opts without a hint" do
      for bare <- [%{"limit" => 2}, %{"offset" => 1}] do
        envelope = Map.merge(%{"page" => %{"limit" => 1}, "fields" => ["id"]}, bare)
        error = gate_error("list_posts", %{"comments" => envelope})

        assert wire_shape(error) == %{
                 "type" => "invalid_query_opts",
                 "fields" => ["comments"],
                 "path" => [],
                 "vars" => %{"field" => "comments"}
               }

        assert error["details"] == %{
                 "suggestion" =>
                   "Use page for paginated results or bare limit/offset for a plain slice"
               }
      end
    end

    test "empty or missing fields inside an envelope is requires_field_selection" do
      for envelope <- [%{"limit" => 1, "fields" => []}, %{"limit" => 1}] do
        error = gate_error("list_posts", %{"comments" => envelope})

        assert wire_shape(error) == %{
                 "type" => "requires_field_selection",
                 "fields" => ["comments"],
                 "path" => [],
                 "vars" => %{"field" => "comments", "fieldType" => "Relationship"}
               }
      end
    end

    test "an unknown page key on a mixed-pagination relationship is invalid_pagination" do
      params = %{
        "action" => "list_posts",
        "fields" => [
          "id",
          %{
            "comments" => %{
              "page" => %{"limit" => 1, "notAPageOptionXyz" => true},
              "fields" => ["id"]
            }
          }
        ]
      }

      # The key stays a string because no such atom exists.
      assert {:error,
              {:invalid_nested_page, :comments, {:unknown_keys, ["not_a_page_option_xyz"]}, []}} =
               parse(params)

      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), params)

      assert wire_shape(error) == %{
               "type" => "invalid_pagination",
               "fields" => ["comments"],
               "path" => [],
               "vars" => %{"field" => "comments"}
             }

      assert error["details"]["reason"] == ~s({:unknown_keys, ["not_a_page_option_xyz"]})
      assert error["details"]["hint"] == hint()
    end

    test "a keyset page key on an offset-only relationship is invalid_pagination" do
      error =
        gate_error("list_posts", %{
          "commentsOffset" => %{
            "page" => %{"limit" => 1, "after" => "cursor"},
            "fields" => ["id"]
          }
        })

      assert wire_shape(error) == %{
               "type" => "invalid_pagination",
               "fields" => ["commentsOffset"],
               "path" => [],
               "vars" => %{"field" => "commentsOffset"}
             }

      assert error["details"]["reason"] == "{:unknown_keys, [:after]}"
    end

    test "an offset page key on a keyset-only relationship is invalid_pagination" do
      error =
        gate_error("list_posts", %{
          "commentsKeyset" => %{"page" => %{"limit" => 1, "offset" => 2}, "fields" => ["id"]}
        })

      assert wire_shape(error) == %{
               "type" => "invalid_pagination",
               "fields" => ["commentsKeyset"],
               "path" => [],
               "vars" => %{"field" => "commentsKeyset"}
             }

      assert error["details"]["reason"] == "{:unknown_keys, [:offset]}"
    end

    test "an envelope on a relationship to an unexposed resource is unknown_field" do
      error = gate_error("list_posts", %{"secrets" => %{"limit" => 1, "fields" => ["id"]}})

      assert wire_shape(error) == %{
               "type" => "unknown_field",
               "fields" => ["secrets"],
               "path" => [],
               "vars" => %{"field" => "secrets", "resource" => "AshRpc.Test.Post"}
             }

      assert error["details"]["hint"] == hint()
    end

    test "a gate failure two levels deep carries the full path" do
      nested = fn inner ->
        %{
          "comments" => %{
            "limit" => 1,
            "fields" => ["id", %{"post" => ["id", inner]}]
          }
        }
      end

      assert %{"success" => true} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_posts",
                 "fields" => [
                   "id",
                   nested.(%{"comments" => %{"page" => %{"limit" => 1}, "fields" => ["id"]}})
                 ]
               })

      error =
        gate_error(
          "list_posts",
          nested.(%{
            "unfilterableComments" => %{
              "filter" => %{"rating" => %{"eq" => 1}},
              "fields" => ["id"]
            }
          })
        )

      assert wire_shape(error) == %{
               "type" => "filter_not_supported",
               "fields" => ["comments.post.unfilterableComments"],
               "path" => ["comments", "post"],
               "vars" => %{"field" => "comments.post.unfilterableComments"}
             }

      assert error["details"]["reason"] == :unsupported
    end
  end

  describe "envelope option values and query build" do
    test "option values pass through byte-identical, even keys spelled like a field-name override" do
      envelope = %{
        "page" => %{"isActive" => true, "limit" => 3, "count" => true},
        "filter" => %{"isActive" => %{"eq" => true}, "title" => %{"eq" => "x"}},
        "sort" => "-isActive",
        "limit" => 5,
        "offset" => 2,
        "fields" => ["id", "isActive"]
      }

      # `isActive` is Author's override for `is_active?`: the top-level name is
      # translated, the envelope under `posts` is left as sent.
      assert RequestedFieldsProcessor.atomize_requested_fields(
               ["id", "isActive", %{"posts" => envelope}],
               Author,
               Runtime.new(@profile)
             ) == ["id", :is_active?, %{"posts" => envelope}]
    end

    test "a full envelope builds a nested query and leaves the template unchanged" do
      assert {:ok, {[:id], [{:comments, %Ash.Query{} = query}], template}} =
               process(Post, [
                 "id",
                 %{
                   "comments" => %{
                     "page" => %{"limit" => 3, "count" => true},
                     "filter" => %{"rating" => %{"greaterThan" => 2}},
                     "sort" => "-rating",
                     "fields" => ["id", "body"]
                   }
                 }
               ])

      assert query.resource == Comment
      assert query.action.name == :read
      assert Enum.sort(query.page) == [count: true, limit: 3]
      assert query.filter == Ash.Filter.parse_input!(Comment, %{rating: %{greater_than: 2}})
      assert query.sort == [rating: :desc]
      assert query.select == [:id, :body]
      assert template == [:id, {:comments, [:id, :body]}]
    end

    test "bare limit and offset build an unpaged query" do
      assert {:ok, {[], [{:comments, %Ash.Query{} = query}], [{:comments, [:id]}]}} =
               process(Post, [%{"comments" => %{"limit" => 2, "offset" => 1, "fields" => ["id"]}}])

      assert query.limit == 2
      assert query.offset == 1
      assert query.page == nil
    end

    test "a fields-only envelope has the plain nested list's template" do
      assert {:ok, {[], [{:comments, %Ash.Query{} = query}], template}} =
               process(Post, [%{"comments" => %{"fields" => ["id"]}}])

      assert {:ok, {[], _load, ^template}} = process(Post, [%{"comments" => ["id"]}])
      assert template == [{:comments, [:id]}]
      assert {query.page, query.limit, query.offset, query.sort} == {nil, nil, 0, []}
    end

    test "atom-keyed envelopes are accepted" do
      assert {:ok, {[], [{:comments, %Ash.Query{} = query}], [{:comments, [:id]}]}} =
               process(Post, [%{comments: %{page: %{limit: 1}, fields: [:id]}}])

      assert query.page == [limit: 1]
      assert query.select == [:id]
    end

    test "an envelope nests inside an envelope two levels deep" do
      assert {:ok, {[], [{:comments, %Ash.Query{} = outer}], template}} =
               process(Post, [
                 %{
                   "comments" => %{
                     "limit" => 2,
                     "fields" => [
                       "id",
                       %{"post" => ["id", %{"comments" => %{"limit" => 1, "fields" => ["id"]}}]}
                     ]
                   }
                 }
               ])

      assert template == [{:comments, [:id, {:post, [:id, {:comments, [:id]}]}]}]
      assert outer.limit == 2
      assert [post: %Ash.Query{load: [comments: %Ash.Query{} = inner]}] = outer.load
      assert inner.limit == 1
      assert inner.select == [:id]

      seed_post(3)

      post =
        list_post_with(%{
          "comments" => %{
            "limit" => 2,
            "sort" => "body",
            "fields" => [
              "body",
              %{
                "post" => [
                  "title",
                  %{"comments" => %{"limit" => 1, "sort" => "-body", "fields" => ["body"]}}
                ]
              }
            ]
          }
        })

      inner_post = %{"title" => "Nested", "comments" => [%{"body" => "comment-3"}]}

      assert post["comments"] == [
               %{"body" => "comment-1", "post" => inner_post},
               %{"body" => "comment-2", "post" => inner_post}
             ]
    end

    test "an envelope is accepted on a get? entrypoint" do
      post = seed_post(3)

      assert %{"success" => true, "data" => data} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "get_post",
                 "fields" => [
                   "id",
                   %{"comments" => %{"limit" => 1, "sort" => "-body", "fields" => ["body"]}}
                 ]
               })

      assert data == %{"id" => post.id, "comments" => [%{"body" => "comment-3"}]}
    end
  end
end
