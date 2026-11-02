# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterInputTest do
  use ExUnit.Case, async: true

  alias AshRpc.FilterInput
  alias AshRpc.Test.{ManifestBuilder, Post, Project}

  setup_all do
    %{
      rt: AshRpc.Runtime.from_manifest(ManifestBuilder.manifest()),
      upcase:
        AshRpc.Runtime.from_manifest(
          ManifestBuilder.build(output_formatter: {AshRpc.Test.Formatters, :upcase})
        )
    }
  end

  describe "parse/3" do
    test "fields, operators, boolean combinators and relationships resolve", %{rt: rt} do
      filter = %{
        "viewCount" => %{"greaterThan" => 1, "isNil" => false},
        "or" => [%{"title" => %{"in" => ["a"]}}, %{"not" => %{"slug" => %{"eq" => "x"}}}],
        "comments" => %{"rating" => %{"gte" => 2}}
      }

      assert FilterInput.parse(rt, Post, filter) ==
               {%{
                  view_count: %{greater_than: 1, is_nil: false},
                  or: [%{title: %{in: ["a"]}}, %{not: %{slug: %{eq: "x"}}}],
                  comments: %{rating: %{gte: 2}}
                }, []}
    end

    test "a function predicate and calculation input args resolve", %{rt: rt} do
      assert {%{title: %{contains: "x"}}, []} =
               FilterInput.parse(rt, Post, %{"title" => %{"contains" => "x"}})

      assert {%{excerpt: %{input: %{length: 2, omission_text: "~"}, eq: "He~"}}, []} =
               FilterInput.parse(rt, Post, %{
                 "excerpt" => %{"input" => %{"length" => 2, "omissionText" => "~"}, "eq" => "He~"}
               })
    end

    test "an unknown field is dropped and reported as NoSuchField with the client's name", %{
      rt: rt
    } do
      assert {%{title: %{eq: "a"}},
              [%Ash.Error.Query.NoSuchField{field: "view_count", path: [:filter]}]} =
               FilterInput.parse(rt, Post, %{
                 "view_count" => %{"eq" => 1},
                 "title" => %{"eq" => "a"}
               })
    end

    test "an unknown operator is reported as NoSuchFilterPredicate", %{rt: rt} do
      assert {%{view_count: %{}}, [%Ash.Error.Query.NoSuchFilterPredicate{key: "greater_than"}]} =
               FilterInput.parse(rt, Post, %{"viewCount" => %{"greater_than" => 1}})
    end

    test "structured operator values take internal names", %{rt: rt} do
      # Embedded resource
      assert FilterInput.parse(rt, Post, %{
               "settings" => %{"eq" => %{"allowComments" => false, "themeName" => "dark"}}
             }) == {%{settings: %{eq: %{allow_comments: false, theme_name: "dark"}}}, []}

      # Typed map with decorated name overrides, under eq and in
      assert FilterInput.parse(rt, Post, %{
               "stats" => %{
                 "eq" => %{"wordCount1" => 3, "isFeatured" => true},
                 "in" => [%{"isFeatured" => false}, nil]
               }
             }) ==
               {%{
                  stats: %{
                    eq: %{word_count_1: 3, is_featured?: true},
                    in: [%{is_featured?: false}, nil]
                  }
                }, []}
    end

    test "a calculation's structured value takes internal names next to its input", %{rt: rt} do
      assert FilterInput.parse(rt, Post, %{
               "scoredStats" => %{"input" => %{"boost" => 1}, "eq" => %{"isFeatured" => true}}
             }) == {%{scored_stats: %{input: %{boost: 1}, eq: %{is_featured?: true}}}, []}
    end

    test "a union value takes its member's internal names", %{rt: rt} do
      assert {%{content: %{eq: %{is_active?: true, title: "t"} = value}}, []} =
               FilterInput.parse(rt, AshRpc.Test.Widget, %{
                 "content" => %{"eq" => %{"checklist" => %{"title" => "t", "isActive" => true}}}
               })

      refute Map.has_key?(value, "isActive")
    end

    test "has on an array field formats its value as one element", %{rt: rt} do
      assert {%{attachments: %{has: %{mime_type: "text/plain", filename: "a"}}}, []} =
               FilterInput.parse(rt, AshRpc.Test.Widget, %{
                 "attachments" => %{
                   "has" => %{"file" => %{"filename" => "a", "mimeType" => "text/plain"}}
                 }
               })
    end

    test "scalar and concrete right-hand sides pass through", %{rt: rt} do
      assert FilterInput.parse(rt, Post, %{
               "settings" => %{"isNil" => false},
               "title" => %{"in" => ["a", "b"], "contains" => "x"}
             }) == {%{settings: %{is_nil: false}, title: %{in: ["a", "b"], contains: "x"}}, []}
    end

    test "an unknown key in an operator value drops the operator and is reported", %{rt: rt} do
      assert {%{stats: %{}, settings: %{}},
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, unknown, []},
                  path: [:filter, field, "eq"]
                },
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, other_unknown, []},
                  path: [:filter, other_field, "eq"]
                }
              ]} =
               FilterInput.parse(rt, Post, %{
                 "stats" => %{"eq" => %{"bogus" => 1}},
                 "settings" => %{"eq" => %{"allowComments" => true, "theme_name" => "x"}}
               })

      assert Enum.sort([{field, unknown}, {other_field, other_unknown}]) ==
               [{"settings", "theme_name"}, {"stats", "bogus"}]
    end

    test "an unknown key inside an in list carries the item index", %{rt: rt} do
      assert {%{stats: %{}},
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, "word_count_1", [1]},
                  path: [:filter, "stats", "in"]
                }
              ]} =
               FilterInput.parse(rt, Post, %{
                 "stats" => %{"in" => [%{"isFeatured" => true}, %{"word_count_1" => 1}]}
               })
    end

    test "the path runs through boolean combinators and list items", %{rt: rt} do
      assert {%{or: [%{title: %{eq: "a"}}, %{stats: %{}}]},
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, "bogus", []},
                  path: [:filter, "or", 1, "stats", "eq"]
                }
              ]} =
               FilterInput.parse(rt, Post, %{
                 "or" => [%{"title" => %{"eq" => "a"}}, %{"stats" => %{"eq" => %{"bogus" => 1}}}]
               })
    end

    test "a malformed union value is reported", %{rt: rt} do
      assert {%{content: %{}},
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:invalid_union_input, :no_member_key, _},
                  path: [:filter, "content", "eq"]
                }
              ]} =
               FilterInput.parse(rt, AshRpc.Test.Widget, %{
                 "content" => %{"eq" => %{"bogus" => 1}}
               })
    end

    test "values under a relationship take the destination's names", %{rt: rt} do
      assert {%{post: %{stats: %{eq: %{is_featured?: true}}, settings: %{}}},
              [%AshRpc.FilterInput.InvalidValue{path: [:filter, "post", "settings", "eq"]}]} =
               FilterInput.parse(rt, AshRpc.Test.Comment, %{
                 "post" => %{
                   "stats" => %{"eq" => %{"isFeatured" => true}},
                   "settings" => %{"eq" => %{"bogus" => 1}}
                 }
               })
    end

    test "calculation input values take internal names", %{rt: rt} do
      assert FilterInput.parse(rt, Post, %{
               "echoStats" => %{
                 "input" => %{"probe" => %{"wordCount1" => 3, "isFeatured" => true}},
                 "isNil" => false
               }
             }) ==
               {%{
                  echo_stats: %{
                    input: %{probe: %{word_count_1: 3, is_featured?: true}},
                    is_nil: false
                  }
                }, []}
    end

    test "an unknown key in a calculation input value drops the field and is reported", %{
      rt: rt
    } do
      assert {statement,
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, "bogus", []},
                  path: [:filter, "echoStats", "input", "probe"]
                }
              ]} =
               FilterInput.parse(rt, Post, %{
                 "echoStats" => %{
                   "input" => %{"probe" => %{"bogus" => 3, "wordCount1" => 1}},
                   "isNil" => false
                 }
               })

      assert statement == %{}
    end

    test "a calculation input name that is not a client name drops the field and is reported",
         %{rt: rt} do
      assert {statement,
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, "omission_text", []},
                  path: [:filter, "excerpt", "input"]
                }
              ]} =
               FilterInput.parse(rt, Post, %{
                 "excerpt" => %{
                   "input" => %{"length" => 3, "omission_text" => "!"},
                   "isNil" => false
                 },
                 "title" => %{"eq" => "a"}
               })

      assert statement == %{title: %{eq: "a"}}
    end

    test "a bare value on a field is eq and takes internal names", %{rt: rt} do
      assert FilterInput.parse(rt, Project, %{
               "history" => [%{"category" => "a", "priorityScore" => 1}],
               "dueDate" => "2026-01-01"
             }) ==
               {%{history: [%{category: "a", priority_score: 1}], due_date: "2026-01-01"}, []}
    end

    test "an unknown key in a bare value drops it and is reported at the field", %{rt: rt} do
      assert {statement,
              [
                %AshRpc.FilterInput.InvalidValue{
                  reason: {:unknown_input, "priority_score", [0]},
                  path: [:filter, "history"]
                }
              ]} = FilterInput.parse(rt, Project, %{"history" => [%{"priority_score" => 1}]})

      assert statement == %{}
    end

    test "a keyword list of operators from a server-side caller passes through", %{rt: rt} do
      # Not a bare eq value: formatted as one, each pair would be a malformed union.
      assert FilterInput.parse(rt, AshRpc.Test.Widget, %{attachments: [is_nil: false]}) ==
               {%{attachments: [is_nil: false]}, []}
    end

    test "a relationship to an unexposed resource is an unknown field", %{rt: rt} do
      # Voucher is decorated (a struct input) but not exposed; Secret is not decorated.
      assert {%{title: %{eq: "a"}},
              [
                %Ash.Error.Query.NoSuchField{field: "secret", path: [:filter]},
                %Ash.Error.Query.NoSuchField{field: "vouchers", path: [:filter]}
              ]} =
               FilterInput.parse(rt, Post, %{
                 "secret" => %{"code" => %{"eq" => "x"}},
                 "title" => %{"eq" => "a"},
                 "vouchers" => %{"voucherCode" => %{"eq" => "x"}}
               })
    end

    test "nil passes through", %{rt: rt} do
      assert FilterInput.parse(rt, Post, nil) == {nil, []}
    end

    test "a custom formatter's names resolve with no inverse", %{upcase: rt} do
      assert FilterInput.parse(rt, Post, %{"VIEW_COUNT" => %{"GREATER_THAN" => 1}}) ==
               {%{view_count: %{greater_than: 1}}, []}
    end

    test "every vocabulary operator alias is accepted by Ash.Query.filter_input/2" do
      for alias_name <- [:equals, :not_equals, :gt, :lt, :gte, :lte] do
        assert %Ash.Query{errors: []} =
                 Ash.Query.filter_input(Post, %{view_count: %{alias_name => 1}})
      end
    end
  end

  describe "parse_sort/3" do
    test "modifiers are kept and names resolved", %{rt: rt} do
      assert FilterInput.parse_sort(rt, Post, "--viewCount,++title") ==
               {"--view_count,++title", []}

      assert FilterInput.parse_sort(rt, Post, ["-viewCount", "title"]) ==
               {"-view_count,title", []}

      assert FilterInput.parse_sort(rt, Post, nil) == {nil, []}
    end

    test "a sort that is not a string or a list is InvalidSort on the sort path", %{rt: rt} do
      sort = %{"viewCount" => "asc"}

      assert {nil, [%Ash.Error.Query.InvalidSort{sort: ^sort, path: [:sort]}]} =
               FilterInput.parse_sort(rt, Post, sort)
    end

    test "a list entry that is not a string is dropped and reported as InvalidSort", %{rt: rt} do
      assert {"-view_count",
              [
                %Ash.Error.Query.InvalidSort{sort: %{"title" => "asc"}, path: [:sort]},
                %Ash.Error.Query.InvalidSort{sort: 1, path: [:sort]}
              ]} = FilterInput.parse_sort(rt, Post, [%{"title" => "asc"}, "-viewCount", 1])
    end

    test "atom entries from a server-side caller are internal names", %{rt: rt} do
      assert FilterInput.parse_sort(rt, Post, [:title]) == {"title", []}
    end

    test "a miss is dropped and reported as NoSuchField on the sort path", %{rt: rt} do
      assert {"title", [%Ash.Error.Query.NoSuchField{field: "view_count", path: [:sort]}]} =
               FilterInput.parse_sort(rt, Post, "-view_count,title")

      assert {nil, [_]} = FilterInput.parse_sort(rt, Post, "-view_count")
    end
  end
end
