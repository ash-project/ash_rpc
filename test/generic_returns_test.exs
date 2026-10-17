# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.GenericReturnsTest do
  use ExUnit.Case, async: true

  alias AshRpc.RequestedFieldsProcessor
  alias AshRpc.Test.{Author, Catalog, Comment, Post}

  @profile AshRpc.Test.Profile

  defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

  defp run(action, fields), do: run(%{"action" => action, "fields" => fields})

  defp process(resource, action, fields) do
    RequestedFieldsProcessor.process(AshRpc.Runtime.new(@profile), resource, action, fields)
  end

  defp data!(%{"success" => true, "data" => data}), do: data

  defp by_title(rows), do: Enum.sort_by(rows, & &1["title"])

  defp seed! do
    author = Ash.create!(Author, %{name: "Ada"})
    alpha = Ash.create!(Post, %{title: "Alpha", view_count: 3, author_id: author.id})
    beta = Ash.create!(Post, %{title: "Beta!", view_count: 7})
    Ash.create!(Comment, %{body: "first", post_id: alpha.id})
    Ash.create!(Comment, %{body: "second", post_id: alpha.id})
    %{author: author, alpha: alpha, beta: beta}
  end

  describe ":struct with field constraints and no instance_of" do
    test "returns only the selected fields" do
      assert run("catalog_struct_summary", ["title", "published"]) |> data!() ==
               %{"title" => "Alpha", "published" => true}
    end

    test "each array item carries only the selected fields" do
      assert run("catalog_struct_summaries", ["wordCount"]) |> data!() ==
               [%{"wordCount" => 3}, %{"wordCount" => 7}]
    end

    test "an unknown field is unknown_field" do
      assert %{"success" => false, "errors" => [%{"type" => "unknown_field"}]} =
               run("catalog_struct_summary", ["title", "missing"])
    end
  end

  describe "{:array, :struct} of a resource" do
    test "each item carries only the selected fields" do
      %{alpha: alpha, beta: beta} = seed!()

      data = run("catalog_search_posts", ["id", "title", "viewCount"]) |> data!()

      assert by_title(data) == [
               %{"id" => alpha.id, "title" => "Alpha", "viewCount" => 3},
               %{"id" => beta.id, "title" => "Beta!", "viewCount" => 7}
             ]
    end

    test "attribute fields are selected and become the template" do
      assert {:ok, {[:id, :title, :view_count], [], [:id, :title, :view_count]}} =
               process(Catalog, :search_posts, ["id", "title", "viewCount"])
    end

    test "relationships load two levels deep with their own selections" do
      seed!()

      data =
        run("catalog_search_posts", [
          "title",
          %{"author" => ["name"]},
          %{"comments" => ["body", %{"post" => ["title"]}]}
        ])
        |> data!()

      assert [alpha, beta] = by_title(data)

      assert Map.update!(alpha, "comments", &Enum.sort_by(&1, fn c -> c["body"] end)) == %{
               "title" => "Alpha",
               "author" => %{"name" => "Ada"},
               "comments" => [
                 %{"body" => "first", "post" => %{"title" => "Alpha"}},
                 %{"body" => "second", "post" => %{"title" => "Alpha"}}
               ]
             }

      assert beta == %{"title" => "Beta!", "author" => nil, "comments" => []}
    end

    test "relationships split into select and load" do
      assert {:ok, {[:title], [author: [:name]], [:title, author: [:name]]}} =
               process(Catalog, :search_posts, ["title", %{"author" => ["name"]}])
    end

    test "calculations and aggregates are loaded on each item" do
      seed!()

      data = run("catalog_search_posts", ["title", "titleLength", "commentCount"]) |> data!()

      assert by_title(data) == [
               %{"title" => "Alpha", "titleLength" => 5, "commentCount" => 2},
               %{"title" => "Beta!", "titleLength" => 5, "commentCount" => 0}
             ]
    end

    test "an empty result is an empty list" do
      assert %{"success" => true, "data" => []} = run("catalog_search_posts", ["id", "title"])
    end
  end

  describe "{:array, :uuid}" do
    test "an empty field list returns the ids" do
      %{alpha: alpha, beta: beta} = seed!()

      assert Enum.sort(run("catalog_post_ids", []) |> data!()) == Enum.sort([alpha.id, beta.id])
    end

    test "an empty field list has an empty template" do
      assert {:ok, {[], [], []}} = process(Catalog, :post_ids, [])
    end

    test "requesting fields is an invalid_field_selection on the primitive type" do
      assert {:error,
              {:invalid_field_selection, :primitive_type, %Ash.Info.Manifest.Type{kind: :uuid},
               [:id], []}} = process(Catalog, :post_ids, [:id])

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_field_selection",
                   "fields" => [],
                   "path" => [],
                   "vars" => %{"returnType" => "UUID"},
                   "details" => %{"requestedFields" => ["id"]}
                 }
               ]
             } = run("catalog_post_ids", ["id"])
    end
  end

  describe "{:array, typed map NewType}" do
    test "items use the type's override names" do
      assert run("catalog_stats_list", ["wordCount1", "isFeatured"]) |> data!() == [
               %{"wordCount1" => 1, "isFeatured" => true},
               %{"wordCount1" => 2, "isFeatured" => false}
             ]
    end

    test "a partial selection applies to every item" do
      assert run("catalog_stats_list", ["isFeatured"]) |> data!() == [
               %{"isFeatured" => true},
               %{"isFeatured" => false}
             ]
    end
  end

  describe "{:array, :map} without constraints" do
    @raw [%{"_id" => "a1", "_type" => "doc", "title" => "One"}]

    test "underscore keys are kept verbatim with an empty field list" do
      assert run("catalog_raw_rows", []) |> data!() == @raw
    end

    test "underscore keys are kept verbatim with no fields param" do
      assert run(%{"action" => "catalog_raw_rows"}) |> data!() == @raw
    end
  end

  describe "date returns" do
    test ":date comes back as an ISO string" do
      assert run("catalog_publication_date", []) |> data!() == "2025-01-15"
    end

    test "{:array, :date} comes back as ISO strings" do
      assert run("catalog_important_dates", []) |> data!() == ["2025-01-15", "2025-02-20"]
    end
  end

  describe "typed map with arrays inside" do
    test "nested selection applies to each item and formats datetimes" do
      assert run("catalog_digest", ["totalCount", %{"results" => ["id", "insertedAt"]}])
             |> data!() == %{
               "totalCount" => 1,
               "results" => [
                 %{
                   "id" => "00000000-0000-0000-0000-000000000001",
                   "insertedAt" => "2025-01-15T10:00:00.000000Z"
                 }
               ]
             }
    end

    test "an array of embedded resources is selected per row" do
      assert run("catalog_digest", [%{"settingsRows" => ["allowComments", "themeName"]}])
             |> data!() == %{
               "settingsRows" => [%{"allowComments" => true, "themeName" => "dark"}]
             }
    end

    test "snake_case selection keys are not client names" do
      assert %{"success" => false, "errors" => [error]} =
               run("catalog_digest", ["total_count", %{"results" => ["firstName", "email"]}])

      assert %{"type" => "unknown_map_field", "fields" => ["total_count"]} = error
    end
  end

  describe "nested typed map selection" do
    test "only the selected nested field is returned" do
      assert run("totals", [%{"byKind" => ["drafts"]}]) |> data!() == %{
               "byKind" => %{"drafts" => 1}
             }
    end

    test "nested and top-level fields combine" do
      assert run("totals", ["total", %{"byKind" => ["drafts"]}]) |> data!() == %{
               "total" => 2,
               "byKind" => %{"drafts" => 1}
             }
    end
  end
end
