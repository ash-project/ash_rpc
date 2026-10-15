# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterSortTest do
  use ExUnit.Case, async: true

  alias AshRpc.Pipeline
  alias AshRpc.Test.{Comment, Post}

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp parse(params), do: Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)

  # Alpha and Charlie share view_count 1; Charlie is the only post without a slug.
  defp seed_posts do
    Ash.create!(Post, %{title: "Alpha", view_count: 1, slug: "alpha"})
    Ash.create!(Post, %{title: "Charlie", view_count: 1})
    Ash.create!(Post, %{title: "Bravo", view_count: 2, slug: "bravo"})
    :ok
  end

  defp list(params) do
    params = Map.put_new(params, "fields", ["title"])
    assert %{"success" => true, "data" => data} = AshRpc.run_action(@profile, ctx(), params)
    data
  end

  defp titles(params), do: params |> list() |> Enum.map(& &1["title"])

  defp list_titles(extra), do: titles(Map.put(extra, "action", "list_posts"))

  defp error_types(params) do
    assert %{"success" => false, "errors" => errors} = AshRpc.run_action(@profile, ctx(), params)
    Enum.map(errors, & &1["type"])
  end

  describe "sort strings" do
    setup do
      seed_posts()
    end

    test "a bare field sorts ascending" do
      assert list_titles(%{"sort" => "title"}) == ["Alpha", "Bravo", "Charlie"]
    end

    test "a - prefix sorts descending" do
      assert list_titles(%{"sort" => "-title"}) == ["Charlie", "Bravo", "Alpha"]
    end

    test "a + prefix sorts ascending" do
      assert list_titles(%{"sort" => "+title"}) == ["Alpha", "Bravo", "Charlie"]
    end

    test "comma-separated fields sort in order, with camelCase names" do
      assert list_titles(%{"sort" => "viewCount,-title"}) == ["Charlie", "Alpha", "Bravo"]
    end
  end

  describe "sort lists" do
    setup do
      seed_posts()
    end

    test "a multi-element list with camelCase names sorts in order" do
      assert list_titles(%{"sort" => ["-viewCount", "title"]}) == ["Bravo", "Alpha", "Charlie"]
    end

    # In-memory asc_nils_first ordering on ETS
    test "a ++ prefix sorts ascending with nils first" do
      assert list_titles(%{"sort" => ["++slug"]}) == ["Charlie", "Alpha", "Bravo"]
    end

    # In-memory desc_nils_last ordering on ETS
    test "a -- prefix sorts descending with nils last" do
      assert list_titles(%{"sort" => ["--slug"]}) == ["Bravo", "Alpha", "Charlie"]
    end
  end

  describe "filter with isNil" do
    setup do
      seed_posts()
    end

    # Sorted by title so ETS order does not matter.
    test "isNil: true keeps records whose field is nil" do
      assert list_titles(%{"filter" => %{"slug" => %{"isNil" => true}}, "sort" => "title"}) ==
               ["Charlie"]
    end

    test "isNil: false keeps records whose field is set" do
      assert list_titles(%{"filter" => %{"slug" => %{"isNil" => false}}, "sort" => "title"}) ==
               ["Alpha", "Bravo"]
    end

    test "isNil inside and" do
      filter = %{
        "and" => [
          %{"slug" => %{"isNil" => false}},
          %{"viewCount" => %{"eq" => 1}}
        ]
      }

      assert list_titles(%{"filter" => filter, "sort" => "title"}) == ["Alpha"]
    end

    test "isNil inside or" do
      filter = %{
        "or" => [
          %{"slug" => %{"isNil" => true}},
          %{"viewCount" => %{"eq" => 2}}
        ]
      }

      assert list_titles(%{"filter" => filter, "sort" => "title"}) == ["Bravo", "Charlie"]
    end

    test "isNil on a defaulted field: false keeps every record, true none" do
      assert list_titles(%{"filter" => %{"viewCount" => %{"isNil" => false}}, "sort" => "title"}) ==
               ["Alpha", "Bravo", "Charlie"]

      assert list_titles(%{"filter" => %{"viewCount" => %{"isNil" => true}}}) == []
    end

    test "filter and sort reach the request with internal names" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "filter" => %{"slug" => %{"isNil" => true}},
                 "sort" => ["-viewCount", "++slug"]
               })

      assert request.filter == %{slug: %{is_nil: true}}
      assert request.sort == "-view_count,++slug"
    end
  end

  # Comment counts: Bravo 2, Alpha 1, Charlie 1, Delta 0. Comment bodies sort
  # first, so firstCommentBody is "nice", "great", "meh" and nil.
  defp seed_rated_posts do
    for {title, comments} <- [
          {"Alpha", [{"nice", 4}]},
          {"Bravo", [{"ok", 3}, {"great", 5}]},
          {"Charlie", [{"meh", 2}]},
          {"Delta", []}
        ] do
      post = Ash.create!(Post, %{title: title})

      for {body, rating} <- comments do
        Ash.create!(Comment, %{body: body, rating: rating, post_id: post.id})
      end
    end

    :ok
  end

  describe "aggregates" do
    setup do
      seed_rated_posts()
    end

    test "a sort on an aggregate breaks ties with a secondary key, as a string or a list" do
      assert list_titles(%{"sort" => "-commentCount,title"}) ==
               ["Bravo", "Alpha", "Charlie", "Delta"]

      assert list_titles(%{"sort" => ["-commentCount", "-title"]}) ==
               ["Bravo", "Charlie", "Alpha", "Delta"]
    end

    test "a max aggregate filters with greaterThanOrEqual" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "maxRating"],
               "filter" => %{"maxRating" => %{"greaterThanOrEqual" => 4}},
               "sort" => "title"
             }) == [
               %{"title" => "Alpha", "maxRating" => 4},
               %{"title" => "Bravo", "maxRating" => 5}
             ]
    end

    test "an avg aggregate filters with greaterThan" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "avgRating"],
               "filter" => %{"avgRating" => %{"greaterThan" => 3}},
               "sort" => "title"
             }) == [
               %{"title" => "Alpha", "avgRating" => 4.0},
               %{"title" => "Bravo", "avgRating" => 4.0}
             ]
    end

    test "a first aggregate filters with eq" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "firstCommentBody"],
               "filter" => %{"firstCommentBody" => %{"eq" => "meh"}}
             }) == [%{"title" => "Charlie", "firstCommentBody" => "meh"}]
    end

    test "a filter on one aggregate combines with a sort on another" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "hasComments", "maxRating"],
               "filter" => %{"hasComments" => %{"eq" => true}},
               "sort" => ["-maxRating"]
             }) == [
               %{"title" => "Bravo", "hasComments" => true, "maxRating" => 5},
               %{"title" => "Alpha", "hasComments" => true, "maxRating" => 4},
               %{"title" => "Charlie", "hasComments" => true, "maxRating" => 2}
             ]
    end

    test "isNil on an aggregate combines with a sort on it" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "maxRating"],
               "filter" => %{"maxRating" => %{"isNil" => false}},
               "sort" => "maxRating"
             }) == [
               %{"title" => "Charlie", "maxRating" => 2},
               %{"title" => "Alpha", "maxRating" => 4},
               %{"title" => "Bravo", "maxRating" => 5}
             ]
    end

    test "aggregates used only in filter and sort stay out of the output" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title"],
               "filter" => %{"maxRating" => %{"greaterThan" => 1}},
               "sort" => "-commentCount,title"
             }) == [%{"title" => "Bravo"}, %{"title" => "Alpha"}, %{"title" => "Charlie"}]
    end
  end

  describe "calculations" do
    setup do
      seed_rated_posts()
    end

    test "a sort on a calculation breaks ties with a secondary key" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title", "titleLength"],
               "sort" => "-titleLength,title"
             }) == [
               %{"title" => "Charlie", "titleLength" => 7},
               %{"title" => "Alpha", "titleLength" => 5},
               %{"title" => "Bravo", "titleLength" => 5},
               %{"title" => "Delta", "titleLength" => 5}
             ]
    end

    test "a calculation filters without being selected" do
      assert list(%{
               "action" => "list_posts",
               "fields" => ["title"],
               "filter" => %{"titleLength" => %{"greaterThan" => 5}}
             }) == [%{"title" => "Charlie"}]
    end

    test "a calculation filter and sort apply before offset pagination" do
      # weightedRating is rating * 2: 8, 6, 10 and 4.
      assert list(%{
               "action" => "list_comments",
               "fields" => ["body", "weightedRating"],
               "filter" => %{"weightedRating" => %{"greaterThan" => 4}},
               "sort" => ["-weightedRating"],
               "page" => %{"limit" => 2, "offset" => 0, "count" => true}
             }) == %{
               "type" => :offset,
               "limit" => 2,
               "offset" => 0,
               "count" => 3,
               "hasMore" => true,
               "results" => [
                 %{"body" => "great", "weightedRating" => 10},
                 %{"body" => "nice", "weightedRating" => 8}
               ]
             }
    end
  end

  describe "enable_filter?: false" do
    test "a filter is rejected as disabled" do
      assert {:error, {:filter_not_supported, :top_level, :disabled}} =
               parse(%{
                 "action" => "list_posts_no_filter",
                 "fields" => ["title"],
                 "filter" => %{"slug" => %{"isNil" => true}}
               })
    end

    test "the wire error is filter_not_supported with reason disabled" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "filter_not_supported",
                   "path" => [],
                   "fields" => [],
                   "details" => %{"reason" => "disabled"}
                 }
               ]
             } =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_posts_no_filter",
                 "fields" => ["title"],
                 "filter" => %{"title" => %{"eq" => "Alpha"}}
               })
    end

    test "an empty filter map still counts as present" do
      assert {:error, {:filter_not_supported, :top_level, :disabled}} =
               parse(%{
                 "action" => "list_posts_no_filter",
                 "fields" => ["title"],
                 "filter" => %{}
               })
    end

    test "an absent or nil filter is allowed" do
      seed_posts()

      assert length(list(%{"action" => "list_posts_no_filter"})) == 3
      assert length(list(%{"action" => "list_posts_no_filter", "filter" => nil})) == 3
    end

    test "sort still works" do
      seed_posts()

      assert titles(%{"action" => "list_posts_no_filter", "sort" => ["-title"]}) ==
               ["Charlie", "Bravo", "Alpha"]
    end
  end

  describe "enable_sort?: false" do
    test "a sort is rejected as disabled" do
      assert {:error, {:sort_not_supported, :top_level, :disabled}} =
               parse(%{
                 "action" => "list_posts_no_sort",
                 "fields" => ["title"],
                 "sort" => "-title"
               })
    end

    test "the wire error is sort_not_supported with reason disabled" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "sort_not_supported",
                   "path" => [],
                   "fields" => [],
                   "details" => %{"reason" => "disabled"}
                 }
               ]
             } =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_posts_no_sort",
                 "fields" => ["title"],
                 "sort" => ["-title", "+viewCount"]
               })
    end

    test "an empty sort string still counts as present" do
      assert {:error, {:sort_not_supported, :top_level, :disabled}} =
               parse(%{"action" => "list_posts_no_sort", "fields" => ["title"], "sort" => ""})
    end

    test "an absent or nil sort is allowed" do
      seed_posts()

      assert length(list(%{"action" => "list_posts_no_sort"})) == 3
      assert length(list(%{"action" => "list_posts_no_sort", "sort" => nil})) == 3
    end

    test "filter still works" do
      seed_posts()

      assert titles(%{
               "action" => "list_posts_no_sort",
               "filter" => %{"slug" => %{"isNil" => true}}
             }) == ["Charlie"]
    end
  end

  describe "both flags disabled" do
    test "filter is checked before sort" do
      params = %{
        "action" => "list_posts_no_filter_no_sort",
        "fields" => ["title"],
        "filter" => %{"title" => %{"eq" => "Alpha"}},
        "sort" => ["-title"]
      }

      assert {:error, {:filter_not_supported, :top_level, :disabled}} = parse(params)
      assert error_types(params) == ["filter_not_supported"]
    end

    test "input and pagination are unaffected" do
      Ash.create!(Comment, %{body: "keep", rating: 4})
      Ash.create!(Comment, %{body: "drop", rating: 1})

      params = %{
        "action" => "list_rated_comments_no_filter_no_sort",
        "fields" => ["body"],
        "input" => %{"minRating" => 3},
        "page" => %{"limit" => 1, "offset" => 0}
      }

      assert {:ok, request} = parse(params)
      # InputFormatter maps minRating to :min_rating and adds no defaults
      assert request.input == %{min_rating: 3}
      assert request.pagination == %{limit: 1, offset: 0}
      assert request.filter == nil
      assert request.sort == nil

      # Ash reports more?: false when one record matches limit: 1
      assert %{"results" => [%{"body" => "keep"}], "hasMore" => false} = list(params)
    end
  end

  describe "non-list reads" do
    test "a filter on a get entrypoint is unsupported, not disabled" do
      assert {:error, {:filter_not_supported, :top_level, :unsupported}} =
               parse(%{
                 "action" => "get_post",
                 "fields" => ["title"],
                 "filter" => %{"title" => %{"eq" => "Alpha"}}
               })
    end

    test "a sort on a get_by entrypoint is unsupported" do
      assert {:error, {:sort_not_supported, :top_level, :unsupported}} =
               parse(%{
                 "action" => "get_post_by_slug",
                 "fields" => ["title"],
                 "getBy" => %{"slug" => "alpha"},
                 "sort" => "-title"
               })
    end
  end

  describe "mutations" do
    test "a filter on a create is unsupported" do
      assert {:error, {:filter_not_supported, :top_level, :unsupported}} =
               parse(%{
                 "action" => "create_post",
                 "fields" => ["title"],
                 "input" => %{"title" => "x"},
                 "filter" => %{"title" => %{"eq" => "Alpha"}}
               })
    end
  end

  describe "top-level page" do
    test "a page on a get? entrypoint is unsupported" do
      params = %{"action" => "get_post", "fields" => ["title"], "page" => %{"limit" => 5}}

      assert {:error, {:pagination_not_supported, :top_level, :unsupported}} = parse(params)
      assert error_types(params) == ["pagination_not_supported"]
    end

    test "an empty page map counts as present" do
      assert {:error, {:pagination_not_supported, :top_level, :unsupported}} =
               parse(%{"action" => "get_post", "fields" => ["title"], "page" => %{}})
    end
  end

  describe "strict client names" do
    setup do
      seed_posts()
    end

    test "an internal snake_case sort name is rejected like an unknown name" do
      assert error_types(%{
               "action" => "list_posts",
               "fields" => ["title"],
               "sort" => "-view_count"
             }) ==
               error_types(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "sort" => "-bogusField"
               })
    end

    test "an internal snake_case filter name is rejected like an unknown name" do
      params =
        &%{"action" => "list_posts", "fields" => ["title"], "filter" => %{&1 => %{"eq" => 1}}}

      assert error_types(params.("view_count")) == error_types(params.("bogusField"))
    end

    test "an internal operator name is rejected" do
      assert %{"success" => false} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "filter" => %{"viewCount" => %{"greater_than" => 1}}
               })
    end

    test "a param key in a non-client casing is dropped like an unknown key" do
      # "Sort" used to lenient-parse to :sort under camelCase
      assert {:ok, request} =
               parse(%{"action" => "list_posts", "fields" => ["title"], "Sort" => "-title"})

      assert request.sort == nil
    end
  end
end
