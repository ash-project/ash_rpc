# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterInputTest do
  use ExUnit.Case, async: true

  alias AshRpc.FilterInput
  alias AshRpc.Test.{ManifestBuilder, Post}

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

    test "a miss is dropped and reported as NoSuchField on the sort path", %{rt: rt} do
      assert {"title", [%Ash.Error.Query.NoSuchField{field: "view_count", path: [:sort]}]} =
               FilterInput.parse_sort(rt, Post, "-view_count,title")

      assert {nil, [_]} = FilterInput.parse_sort(rt, Post, "-view_count")
    end
  end
end
