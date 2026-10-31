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

  defp metadata_error(action, metadata_fields) do
    assert %{"success" => false, "errors" => [error]} =
             run(%{
               "action" => action,
               "fields" => ["id", "title"],
               "metadataFields" => metadata_fields
             })

    error
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

    test "a non-client metadata name is rejected" do
      create_post("Strict")

      assert %{"type" => "unknown_metadata_fields", "fields" => ["total_score"]} =
               error =
               metadata_error("read_posts_with_metadata", ["total_score", "meta1"])

      assert error["path"] == ["metadataFields"]

      assert error["details"]["allowedFields"] ==
               ["totalScore", "meta1", "isCached", "breakdown", "extra"]
    end

    test "requested fields that are not exposed are rejected" do
      create_post("Some exposed")

      error =
        metadata_error("read_posts_with_some_metadata", [
          "totalScore",
          "meta1",
          "isCached",
          "breakdown",
          "extra"
        ])

      assert error["fields"] == ["isCached", "breakdown", "extra"]
      assert error["details"]["allowedFields"] == ["totalScore", "meta1"]
    end

    test "an entrypoint exposing no metadata rejects every requested field" do
      create_post("None exposed")

      error =
        metadata_error("read_posts_without_metadata", ["totalScore", "meta1", "isCached"])

      assert error["fields"] == ["totalScore", "meta1", "isCached"]
      assert error["details"]["allowedFields"] == []
    end

    test "an action without metadata rejects metadataFields" do
      create_post("Plain")

      assert %{"fields" => ["totalScore"]} = metadata_error("list_posts", ["totalScore"])
    end

    test "an empty metadataFields list is not an error" do
      post = create_post("Empty")

      assert read_one("read_posts_with_metadata", post, []) == %{
               "id" => post.id,
               "title" => "Empty"
             }
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
    test "internal names are not client names and are rejected" do
      create_post("Original names")

      assert %{"type" => "unknown_metadata_fields", "fields" => ["meta_1", "is_cached?"]} =
               metadata_error("read_posts_with_metadata", ["meta_1", "is_cached?"])
    end

    test "mapped metadata names containing underscores are preserved verbatim in mutation responses" do
      manifest =
        [
          %{
            resource: AshRpc.Test.Post,
            action: :create_with_metadata,
            config: %{
              ash_rpc_test: %{
                name: "create_post_snake_meta",
                opts: [
                  exposed_metadata_fields: [:total_score, :meta_1],
                  metadata_field_names: %{meta_1: "some_string_value"}
                ]
              }
            }
          }
        ]
        |> AshRpc.Test.ManifestBuilder.generate!()
        |> AshRpc.Manifest.Decorator.decorate(AshRpc.Test.MappingSource, [])

      assert %{"success" => true, "metadata" => metadata} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "action" => "create_post_snake_meta",
                   "input" => %{"title" => "Snake mapped meta"},
                   "fields" => ["id"]
                 },
                 manifest: manifest
               )

      assert metadata == %{"totalScore" => 42, "some_string_value" => "m1"}
    end

    test "mapped metadata names are preserved verbatim in mutation responses under :pascal_case" do
      manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)

      assert %{"Success" => true, "Metadata" => metadata} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "Action" => "create_post_with_metadata",
                   "input" => %{"Title" => "Pascal meta"},
                   "Fields" => ["Id"],
                   "MetadataFields" => ["TotalScore", "meta1", "isCached"]
                 },
                 manifest: manifest
               )

      assert metadata == %{"TotalScore" => 42, "meta1" => "m1", "isCached" => true}
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
