# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ActionMetadataTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  # Every `*_with_metadata` Post action sets (AshRpc.Test.Changes.Metadata):
  # total_score: 42, meta_1: "m1", is_cached?: true,
  # breakdown: %{top_score: 9, tag_names: ["a", "b"]} (typed map),
  # extra: %{"_id" => "x-1", "snake_key" => %{"_rev" => 1, "nested_key" => "v"}}
  # (unconstrained map). Entrypoints with metadata map meta_1 -> "meta1" and
  # is_cached? -> "isCached".

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp create_post(title), do: Ash.create!(AshRpc.Test.Post, %{title: title})

  defp read_one(action, post, metadata_fields) do
    params = %{"action" => action, "fields" => ["id", "title"]}

    params =
      if metadata_fields,
        do: Map.put(params, "metadataFields", metadata_fields),
        else: params

    assert %{"success" => true, "data" => records} = run(params)
    assert %{} = record = Enum.find(records, &(&1["id"] == post.id))
    record
  end

  describe "read actions" do
    test "requested metadata fields are merged into each record" do
      first = create_post("First")
      second = create_post("Second")

      assert %{"success" => true, "data" => records} =
               run(%{
                 "action" => "read_posts_with_metadata",
                 "fields" => ["id", "title"],
                 "metadataFields" => ["totalScore", "meta1", "isCached"]
               })

      assert length(records) == 2

      for post <- [first, second] do
        record = Enum.find(records, &(&1["id"] == post.id))

        assert record == %{
                 "id" => post.id,
                 "title" => post.title,
                 "totalScore" => 42,
                 "meta1" => "m1",
                 "isCached" => true
               }
      end
    end

    test "only the requested subset of exposed fields is merged" do
      post = create_post("Subset")

      record = read_one("read_posts_with_metadata", post, ["totalScore"])

      assert record["totalScore"] == 42
      refute Map.has_key?(record, "meta1")
      refute Map.has_key?(record, "isCached")
      refute Map.has_key?(record, "breakdown")
      refute Map.has_key?(record, "extra")
    end

    test "no metadataFields param merges no metadata" do
      post = create_post("None requested")

      record = read_one("read_posts_with_metadata", post, nil)

      assert record == %{"id" => post.id, "title" => "None requested"}
    end

    test "requested fields that are not exposed are silently dropped" do
      post = create_post("Some exposed")

      record =
        read_one("read_posts_with_some_metadata", post, [
          "totalScore",
          "meta1",
          "isCached",
          "breakdown",
          "extra"
        ])

      assert record == %{
               "id" => post.id,
               "title" => "Some exposed",
               "totalScore" => 42,
               "meta1" => "m1"
             }
    end

    test "an entrypoint exposing no metadata drops every requested field" do
      post = create_post("None exposed")

      record =
        read_one("read_posts_without_metadata", post, ["totalScore", "meta1", "isCached"])

      assert record == %{"id" => post.id, "title" => "None exposed"}
    end

    test "an action without metadata ignores metadataFields" do
      post = create_post("Plain")

      result =
        run(%{
          "action" => "list_posts",
          "fields" => ["id", "title"],
          "metadataFields" => ["totalScore"]
        })

      assert %{"success" => true, "data" => [record]} = result
      refute Map.has_key?(result, "metadata")
      assert record == %{"id" => post.id, "title" => "Plain"}
    end
  end

  describe "mutation actions" do
    test "create returns every exposed field under a top-level metadata key" do
      result =
        run(%{
          "action" => "create_post_with_metadata",
          "input" => %{"title" => "Created"},
          "fields" => ["id", "title"]
        })

      assert %{"success" => true, "data" => data, "metadata" => metadata} = result
      # Metadata is not merged into the record for mutations.
      assert Map.keys(data) |> Enum.sort() == ["id", "title"]
      assert data["title"] == "Created"

      assert Map.keys(metadata) |> Enum.sort() ==
               ["breakdown", "extra", "isCached", "meta1", "totalScore"]

      assert metadata["totalScore"] == 42
      assert metadata["meta1"] == "m1"
      assert metadata["isCached"] == true
    end

    test "metadataFields narrows the mutation metadata object" do
      assert %{"success" => true, "metadata" => metadata} =
               run(%{
                 "action" => "create_post_with_metadata",
                 "input" => %{"title" => "Narrowed"},
                 "fields" => ["id"],
                 "metadataFields" => ["meta1", "totalScore"]
               })

      assert metadata == %{"meta1" => "m1", "totalScore" => 42}
    end

    test "update returns metadata alongside the updated record" do
      post = create_post("Original")

      # Bulk update (stream strategy) returns the record as modified by the
      # after_action hook, so __metadata__ survives.
      assert %{"success" => true, "data" => data, "metadata" => metadata} =
               run(%{
                 "action" => "update_post_with_metadata",
                 "identity" => post.id,
                 "input" => %{"title" => "Updated"},
                 "fields" => ["id", "title"]
               })

      assert data == %{"id" => post.id, "title" => "Updated"}
      assert metadata["totalScore"] == 42
      assert metadata["meta1"] == "m1"
      assert metadata["isCached"] == true
    end

    test "destroy without fields returns empty data and the metadata" do
      post = create_post("To delete")

      # Bulk destroy with return_records?: true returns the record with the
      # metadata set by the after_action hook.
      assert %{"success" => true, "data" => data, "metadata" => metadata} =
               run(%{"action" => "destroy_post_with_metadata", "identity" => post.id})

      assert data == %{}
      assert metadata["totalScore"] == 42
      assert metadata["meta1"] == "m1"
      assert metadata["isCached"] == true
      assert [] = Ash.read!(AshRpc.Test.Post)
    end

    test "no metadata key when the entrypoint exposes none" do
      result =
        run(%{
          "action" => "create_post_without_metadata",
          "input" => %{"title" => "Bare"},
          "fields" => ["id", "title"]
        })

      assert %{"success" => true, "data" => %{"title" => "Bare"}} = result
      refute Map.has_key?(result, "metadata")
    end
  end

  describe "metadata field names" do
    test "original names are accepted in requests but output stays mapped" do
      post = create_post("Original names")

      record = read_one("read_posts_with_metadata", post, ["meta_1", "is_cached?"])

      assert record["meta1"] == "m1"
      assert record["isCached"] == true
      refute Map.has_key?(record, "meta_1")
      refute Map.has_key?(record, "is_cached?")
      refute Map.has_key?(record, "isCached?")
    end
  end

  describe "metadata value formatting" do
    test "typed-map metadata has its nested keys formatted" do
      post = create_post("Typed")

      record = read_one("read_posts_with_metadata", post, ["breakdown"])

      assert record["breakdown"] == %{"topScore" => 9, "tagNames" => ["a", "b"]}
    end

    test "unconstrained-map metadata passes through verbatim on read" do
      post = create_post("Raw read")

      record = read_one("read_posts_with_metadata", post, ["extra"])

      assert record["extra"] == %{
               "_id" => "x-1",
               "snake_key" => %{"_rev" => 1, "nested_key" => "v"}
             }
    end

    test "unconstrained-map metadata passes through verbatim on create" do
      assert %{"success" => true, "metadata" => metadata} =
               run(%{
                 "action" => "create_post_with_metadata",
                 "input" => %{"title" => "Raw create"},
                 "fields" => ["id"],
                 "metadataFields" => ["extra"]
               })

      assert metadata == %{
               "extra" => %{
                 "_id" => "x-1",
                 "snake_key" => %{"_rev" => 1, "nested_key" => "v"}
               }
             }
    end
  end
end
