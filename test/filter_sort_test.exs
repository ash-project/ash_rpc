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

  defp run_error(params) do
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        AshRpc.run_action(@profile, ctx(), Map.put_new(params, "fields", ["title"]))
      end)

    # The log is shared with concurrent tests, so look only for these errors
    refute log =~ "Error type: Ash.Error.Query.NoSuch"
    assert %{"success" => false, "errors" => [error]} = result
    error
  end

  describe "unknown names" do
    setup do
      seed_posts()
    end

    test "an unknown sort field is unknown_field naming the field as sent" do
      error = run_error(%{"action" => "list_posts", "sort" => "-view_count"})

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["view_count"]
      assert error["vars"]["field"] == "view_count"
      assert error["path"] == ["sort"]
    end

    test "an unknown filter field is unknown_field naming the field as sent" do
      error = run_error(%{"action" => "list_posts", "filter" => %{"view_count" => %{"eq" => 1}}})

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["view_count"]
      assert error["vars"]["field"] == "view_count"
      assert error["path"] == ["filter"]
    end

    test "an unknown key in a filter value is unknown_input with the filter path" do
      error =
        run_error(%{
          "action" => "list_posts",
          "filter" => %{"stats" => %{"eq" => %{"isFeatured" => true, "word_count_1" => 1}}}
        })

      assert error["type"] == "unknown_input"
      assert error["fields"] == ["word_count_1"]
      assert error["vars"]["field"] == "word_count_1"
      assert error["path"] == ["filter", "stats", "eq"]
      assert error["details"]["hint"] == AshRpc.Profile.default_stale_client_hint()
    end

    test "eq on an embedded resource is unknown_filter_operator" do
      error =
        run_error(%{
          "action" => "list_posts",
          "filter" => %{"settings" => %{"eq" => %{"themeName" => "x"}}}
        })

      assert error["type"] == "unknown_filter_operator"
      assert error["path"] == ["filter", "settings"]
    end

    test "an unknown filter operator is unknown_filter_operator naming it as sent" do
      error =
        run_error(%{"action" => "list_posts", "filter" => %{"viewCount" => %{"bogusOp" => 1}}})

      assert error["type"] == "unknown_filter_operator"
      assert error["fields"] == ["bogusOp"]
      assert error["vars"]["operator"] == "bogusOp"
      assert error["path"] == ["filter", "viewCount"]
    end

    test "an unknown key in a calculation input value is unknown_input under input" do
      error =
        run_error(%{
          "action" => "list_posts",
          "filter" => %{
            "excerpt" => %{"input" => %{"length" => 3, "omission_text" => "!"}, "isNil" => false}
          }
        })

      assert error == %{
               "type" => "unknown_input",
               "message" => "Unknown input %{field}",
               "shortMessage" => "Unknown input",
               "vars" => %{"field" => "omission_text"},
               "fields" => ["omission_text"],
               "path" => ["filter", "excerpt", "input"],
               "details" => %{"hint" => AshRpc.Profile.default_stale_client_hint()}
             }

      error =
        run_error(%{
          "action" => "list_posts",
          "filter" => %{"echoStats" => %{"input" => %{"probe" => %{"bogus" => 3}}}}
        })

      assert error["type"] == "unknown_input"
      assert error["fields"] == ["bogus"]
      assert error["path"] == ["filter", "echoStats", "input", "probe"]
    end

    test "an unknown key in a bare filter value is unknown_input at the field" do
      error =
        run_error(%{
          "action" => "list_widgets",
          "fields" => ["id"],
          "filter" => %{"attachments" => [%{"file" => %{"filename" => "a", "mime_type" => "x"}}]}
        })

      assert error["type"] == "unknown_input"
      assert error["fields"] == ["mime_type"]
      assert error["path"] == ["filter", "attachments", 0, "file"]
    end

    test "a filter through a relationship to an unexposed resource is unknown_field" do
      error =
        run_error(%{
          "action" => "list_posts",
          "filter" => %{"vouchers" => %{"voucherCode" => %{"eq" => "x"}}}
        })

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["vouchers"]
      assert error["path"] == ["filter"]
    end

    test "unknown filter and sort names carry the stale-client hint" do
      error = run_error(%{"action" => "list_posts", "sort" => "view_count"})
      assert is_binary(error["details"]["hint"])
    end
  end

  # Ash reports errors from a nested load's query under `[:load, relationship]`;
  # the client sees the relationships it selected through.
  describe "errors in nested query options" do
    defp nested_error(fields), do: run_error(%{"action" => "list_posts", "fields" => fields})

    test "an unknown filter operator two relationships deep" do
      error =
        nested_error([
          %{
            "author" => [
              %{"posts" => %{"fields" => ["id"], "filter" => %{"viewCount" => %{"zz" => 1}}}}
            ]
          }
        ])

      assert error["type"] == "unknown_filter_operator"
      assert error["path"] == ["author", "posts", "filter", "viewCount"]
    end

    test "an unknown sort field" do
      error = nested_error([%{"comments" => %{"fields" => ["id"], "sort" => "nope"}}])

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["nope"]
      assert error["path"] == ["comments", "sort"]
    end

    test "an unknown filter field" do
      error =
        nested_error([
          %{"comments" => %{"fields" => ["id"], "filter" => %{"nope" => %{"eq" => 1}}}}
        ])

      assert error["type"] == "unknown_field"
      assert error["path"] == ["comments", "filter"]
    end

    test "an unknown key in a filter value" do
      filter = %{"attachment" => %{"eq" => %{"file" => %{"bogus" => 1}}}}
      error = nested_error([%{"comments" => %{"fields" => ["id"], "filter" => filter}}])

      assert error["type"] == "unknown_input"
      assert error["path"] == ["comments", "filter", "attachment", "eq", "file"]
    end
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

  describe "invalid sort shapes" do
    @invalid_sort %{
      "type" => "invalid_sort",
      "message" => "Invalid sort",
      "shortMessage" => "Invalid sort",
      "vars" => %{},
      "fields" => [],
      "path" => ["sort"],
      "details" => %{
        "expected" =>
          "A string or a list of strings, each a field name with an optional +, -, ++ or -- prefix"
      }
    }

    test "a sort map is invalid_sort" do
      assert run_error(%{"action" => "list_posts", "sort" => %{"view_count" => "asc"}}) ==
               @invalid_sort
    end

    test "a sort list with a map entry is invalid_sort" do
      assert run_error(%{"action" => "list_posts", "sort" => [%{"title" => "asc"}]}) ==
               @invalid_sort
    end

    test "a nested sort map is invalid_sort" do
      error =
        run_error(%{
          "action" => "list_posts",
          "fields" => [%{"comments" => %{"sort" => %{"rating" => "asc"}, "fields" => ["body"]}}]
        })

      assert error == %{@invalid_sort | "path" => ["comments", "sort"]}
    end
  end

  describe "invalid filter values" do
    defp invalid_filter_value(path, expected) do
      %{
        "type" => "invalid_filter_value",
        "message" => "Invalid filter value",
        "shortMessage" => "Invalid filter value",
        "vars" => %{},
        "fields" => [],
        "path" => path,
        "details" => %{"expected" => expected}
      }
    end

    defp filter_error(filter), do: run_error(%{"action" => "list_posts", "filter" => filter})

    test "an in that is not a list is invalid_filter_value at the operator" do
      for {filter, field} <- [
            {%{"title" => %{"in" => "x"}}, "title"},
            {%{"stats" => %{"in" => %{"a" => 1}}}, "stats"}
          ] do
        assert filter_error(filter) == invalid_filter_value(["filter", field, "in"], "A list")
      end
    end

    test "a value the operator's concrete type can't cast is invalid_filter_value" do
      for {filter, field, op, expected} <- [
            {%{"title" => %{"isNil" => "yes"}}, "title", "isNil", "A boolean value"},
            {%{"stats" => %{"isNil" => %{"x" => 1}}}, "stats", "isNil", "A boolean value"},
            {%{"title" => %{"contains" => %{"a" => 1}}}, "title", "contains", "A string value"}
          ] do
        assert filter_error(filter) == invalid_filter_value(["filter", field, op], expected)
      end
    end

    test "the path runs through relationships and and/or" do
      assert filter_error(%{"or" => [%{"author" => %{"posts" => %{"title" => %{"in" => 1}}}}]}) ==
               invalid_filter_value(
                 ["filter", "or", 0, "author", "posts", "title", "in"],
                 "A list"
               )
    end

    test "an operand Ash rejects is invalid_filter_value without Ash's message" do
      error = filter_error(%{"id" => %{"in" => [%{"a" => 1}]}})

      assert error == %{
               "type" => "invalid_filter_value",
               "message" => "Invalid filter value",
               "shortMessage" => "Invalid filter value",
               "vars" => %{},
               "fields" => [],
               "path" => ["filter"],
               "details" => %{}
             }
    end

    test "a relationship given a boolean is invalid_filter at the relationship" do
      assert run_error(%{"action" => "list_posts", "filter" => %{"comments" => true}}) ==
               invalid_filter(["filter", "comments"])
    end

    test "input on a field that is not a calculation is unknown_filter_operator at the field" do
      error = filter_error(%{"title" => %{"input" => %{}}})

      assert error["type"] == "unknown_filter_operator"
      assert error["fields"] == ["input"]
      assert error["path"] == ["filter", "title"]
    end

    test "an unknown field under a relationship is unknown_field at the relationship" do
      error = filter_error(%{"author" => %{"posts" => %{"bogus" => 1}}})

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["bogus"]
      assert error["vars"] == %{"field" => "bogus"}
      assert error["path"] == ["filter", "author", "posts"]
    end
  end

  describe "calculation arguments in filters" do
    defp calc_arg_error(path, arg, message) do
      %{
        "type" => "invalid_calculation_argument",
        "message" => message,
        "shortMessage" => "Invalid calculation argument",
        "vars" => %{"field" => arg},
        "fields" => [arg],
        "path" => path
      }
    end

    defp comments_filter_error(filter),
      do: run_error(%{"action" => "list_comments", "fields" => ["id"], "filter" => filter})

    test "a value that doesn't cast names the full path through a relationship" do
      filter = %{"post" => %{"excerpt" => %{"input" => %{"length" => "x"}, "eq" => "a"}}}

      assert comments_filter_error(filter) ==
               calc_arg_error(["filter", "post", "excerpt", "input"], "length", "is invalid")
    end

    test "a value that doesn't cast names the full path through or" do
      filter = %{"or" => [%{"excerpt" => %{"input" => %{"length" => "x"}, "eq" => "a"}}]}

      assert run_error(%{"action" => "list_posts", "filter" => filter}) ==
               calc_arg_error(["filter", "or", 0, "excerpt", "input"], "length", "is invalid")
    end

    test "a missing required argument is reported without an input map" do
      for filter <- [
            %{"author" => %{"posts" => %{"excerpt" => %{"eq" => "x"}}}},
            %{"author" => %{"posts" => %{"excerpt" => "x"}}},
            %{"author" => %{"posts" => %{"excerpt" => %{"input" => %{"length" => nil}}}}}
          ] do
        assert run_error(%{"action" => "list_posts", "filter" => filter}) ==
                 calc_arg_error(
                   ["filter", "author", "posts", "excerpt", "input"],
                   "length",
                   "is required"
                 )
      end
    end

    test "a multi-word argument takes its client name" do
      filter = %{
        "excerpt" => %{"input" => %{"length" => 2, "omissionText" => %{"a" => 1}}, "eq" => "a"}
      }

      assert run_error(%{"action" => "list_posts", "filter" => filter}) ==
               calc_arg_error(["filter", "excerpt", "input"], "omissionText", "is invalid")
    end

    test "valid arguments still filter" do
      seed_posts()

      filter = %{"excerpt" => %{"input" => %{"length" => 2}, "eq" => "Al"}}
      assert list_titles(%{"filter" => filter}) == ["Alpha"]
    end
  end

  describe "unsortable fields" do
    defp unsortable(field, reason) do
      %{
        "type" => "unsortable_field",
        "message" => "Cannot sort on %{field}",
        "shortMessage" => "Unsortable field",
        "vars" => %{"field" => field},
        "fields" => [field],
        "path" => ["sort"],
        "details" => %{"reason" => reason}
      }
    end

    test "a relationship is unsortable_field" do
      for name <- ["author", "comments", "-author"] do
        assert run_error(%{"action" => "list_posts", "sort" => name}) ==
                 unsortable(String.trim_leading(name, "-"), "relationship")
      end
    end

    test "a relationship to an unexposed resource is unknown_field" do
      error = run_error(%{"action" => "list_posts", "sort" => "secret"})

      assert error["type"] == "unknown_field"
      assert error["fields"] == ["secret"]
      assert error["path"] == ["sort"]
    end

    test "a calculation with required arguments is unsortable_field" do
      assert run_error(%{"action" => "list_posts", "sort" => "excerpt"}) ==
               unsortable("excerpt", "requires_arguments")
    end

    test "in a nested sort the path starts at the relationship" do
      error =
        run_error(%{
          "action" => "list_posts",
          "fields" => [%{"comments" => %{"fields" => ["id"], "sort" => "post"}}]
        })

      assert error == %{unsortable("post", "relationship") | "path" => ["comments", "sort"]}
    end
  end

  describe "invalid filter shapes" do
    defp invalid_filter(path) do
      %{
        "type" => "invalid_filter",
        "message" => "Invalid filter statement",
        "shortMessage" => "Invalid filter",
        "vars" => %{},
        "fields" => [],
        "path" => path,
        "details" => %{
          "expected" =>
            "A map of field names, relationships and and/or/not to conditions, or a list of such maps"
        }
      }
    end

    test "a filter that is not a map or a list is invalid_filter" do
      for filter <- ["title", 5] do
        assert run_error(%{"action" => "list_posts", "filter" => filter}) ==
                 invalid_filter(["filter"])
      end
    end

    test "a filter list entry that is not a map is invalid_filter at its index" do
      assert run_error(%{"action" => "list_posts", "filter" => [%{"title" => "a"}, "title"]}) ==
               invalid_filter(["filter", 1])
    end

    test "and/or/not given a scalar is invalid_filter at the operator" do
      assert run_error(%{"action" => "list_posts", "filter" => %{"and" => "x"}}) ==
               invalid_filter(["filter", "and"])

      assert run_error(%{"action" => "list_posts", "filter" => %{"not" => nil}}) ==
               invalid_filter(["filter", "not"])

      assert run_error(%{"action" => "list_posts", "filter" => %{"or" => [nil]}}) ==
               invalid_filter(["filter", "or", 0])
    end

    test "an empty and/or is invalid_filter at the operator" do
      for op <- ["and", "or"], value <- [[], %{}, ["x"]] do
        assert run_error(%{"action" => "list_posts", "filter" => %{op => value}}) ==
                 invalid_filter(if value == ["x"], do: ["filter", op, 0], else: ["filter", op])
      end
    end

    test "a calculation input that is not a map is invalid_calculation_args at input" do
      for input <- [[1], "x"] do
        filter = %{"excerpt" => %{"input" => input, "eq" => "x"}}

        assert run_error(%{"action" => "list_posts", "filter" => filter}) == %{
                 "type" => "invalid_calculation_args",
                 "message" => "Calculation input must be a map",
                 "shortMessage" => "Invalid calculation arguments",
                 "vars" => %{},
                 "fields" => [],
                 "path" => ["filter", "excerpt", "input"],
                 "details" => %{"expected" => "Map of argument names to values"}
               }
      end
    end

    test "a relationship given a scalar is invalid_filter at the relationship" do
      assert run_error(%{"action" => "list_posts", "filter" => %{"author" => "x"}}) ==
               invalid_filter(["filter", "author"])
    end

    test "a nested filter that is not a map is invalid_filter under the relationship" do
      for filter <- ["x", ["x"]] do
        error =
          run_error(%{
            "action" => "list_posts",
            "fields" => [%{"comments" => %{"fields" => ["id"], "filter" => filter}}]
          })

        expected_path =
          if is_list(filter), do: ["comments", "filter", 0], else: ["comments", "filter"]

        assert error == invalid_filter(expected_path)
      end
    end

    test "a boolean filter still passes to Ash" do
      seed_posts()
      assert "Alpha" in list_titles(%{"filter" => true})
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
