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
      # `details.reason` stays an atom on the wire, as in error_builder_golden_test.exs
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "filter_not_supported",
                   "path" => [],
                   "fields" => [],
                   "details" => %{"reason" => :disabled}
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
      # `details.reason` stays an atom on the wire, as in error_builder_golden_test.exs
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "sort_not_supported",
                   "path" => [],
                   "fields" => [],
                   "details" => %{"reason" => :disabled}
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
  end
end
