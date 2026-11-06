# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.RunActionTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp parse(params),
    do: AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)

  defp with_fields(params, :omit), do: params
  defp with_fields(params, fields), do: Map.put(params, "fields", fields)

  test "create then list through the wire contract" do
    assert %{"success" => true, "data" => %{"title" => "Hello"}} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "create_post",
               "input" => %{"title" => "Hello"},
               "fields" => ["title"]
             })

    assert %{"success" => true, "data" => [%{"title" => "Hello"}]} =
             AshRpc.run_action(@profile, ctx(), %{"action" => "list_posts", "fields" => ["title"]})
  end

  test "argument overrides apply to input" do
    assert %{"success" => true, "data" => 2} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "word_count",
               "input" => %{"body" => "two words"}
             })
  end

  test "a bad argument cast on a generic action is invalid_argument" do
    # `text` is renamed `body` by argument_names; the error names it the way
    # the client sent it.
    assert %{
             "success" => false,
             "errors" => [
               %{
                 "type" => "invalid_argument",
                 "fields" => ["body"],
                 "vars" => %{"field" => "body"}
               }
             ]
           } =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "word_count",
               "input" => %{"body" => %{"not" => "a string"}}
             })
  end

  test "unknown action and missing action" do
    assert %{"success" => false, "errors" => [%{"type" => "action_not_found"}]} =
             AshRpc.run_action(@profile, ctx(), %{"action" => "nope"})

    assert %{"success" => false, "errors" => [%{"type" => "missing_required_parameter"}]} =
             AshRpc.run_action(@profile, ctx(), %{})
  end

  describe "exceptions raised while handling a request" do
    import ExUnit.CaptureLog

    # An `entrypoint:` option naming an action the manifest doesn't have makes
    # `Introspection.get_action!/3` raise inside parse_request.
    @missing_entrypoint %AshRpc.Entrypoint{
      name: "missing",
      resource: AshRpc.Test.Post,
      action: :not_in_manifest
    }

    test "run_action logs them with a stacktrace and returns unknown_error" do
      {response, log} =
        with_log(fn ->
          AshRpc.run_action(@profile, ctx(), %{}, entrypoint: @missing_entrypoint)
        end)

      assert %{"success" => false, "errors" => [%{"type" => "unknown_error"}]} = response
      assert log =~ "** (RuntimeError) action :not_in_manifest not found on AshRpc.Test.Post"
      assert log =~ "lib/ash_rpc/pipeline.ex"
    end

    test "validate_action logs them with a stacktrace and returns unknown_error" do
      {response, log} =
        with_log(fn ->
          AshRpc.validate_action(@profile, ctx(), %{}, entrypoint: @missing_entrypoint)
        end)

      assert %{"success" => false, "errors" => [%{"type" => "unknown_error"}]} = response
      assert log =~ "** (RuntimeError) action :not_in_manifest not found on AshRpc.Test.Post"
      assert log =~ "lib/ash_rpc/pipeline.ex"
    end
  end

  test "manifest: option changes output casing" do
    manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)

    assert %{"Success" => true, "Data" => %{"ViewCount" => 0}} =
             AshRpc.run_action(
               @profile,
               ctx(),
               %{
                 "Action" => "create_post",
                 "Input" => %{"Title" => "x"},
                 "Fields" => ["ViewCount"]
               },
               manifest: manifest
             )
  end

  describe "input and identity keys under a non-camel formatter" do
    setup do
      %{manifest: AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)}
    end

    test "Identity and Input are read under their formatted names", %{manifest: manifest} do
      post = Ash.create!(AshRpc.Test.Post, %{title: "Old"})

      assert %{"Success" => true, "Data" => %{"Title" => "New"}} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "Action" => "update_post",
                   "Identity" => post.id,
                   "Input" => %{"Title" => "New"},
                   "Fields" => ["Title"]
                 },
                 manifest: manifest
               )

      assert %{"Success" => true, "Data" => %{"Title" => "New"}} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{"Action" => "destroy_post", "Identity" => post.id, "Fields" => ["Title"]},
                 manifest: manifest
               )
    end

    test "lowercase input and identity are not read", %{manifest: manifest} do
      post = Ash.create!(AshRpc.Test.Post, %{title: "Old"})

      assert %{"Success" => false, "Errors" => [%{"Type" => "required", "Fields" => ["Title"]}]} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "Action" => "create_post",
                   "input" => %{"Title" => "x"},
                   "Fields" => ["Title"]
                 },
                 manifest: manifest
               )

      assert %{"Success" => false, "Errors" => [%{"Type" => "missing_identity"} | _]} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{"Action" => "update_post", "identity" => post.id, "Fields" => ["Title"]},
                 manifest: manifest
               )
    end
  end

  test "update returns only the selected fields and loads relationships" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Old", view_count: 3, author_id: author.id})

    assert %{"success" => true, "data" => data} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "update_post",
               "identity" => post.id,
               "input" => %{"title" => "New"},
               "fields" => ["title", %{"author" => ["name"]}]
             })

    assert data == %{"title" => "New", "author" => %{"name" => "Ada"}}
  end

  test "destroy returns only the selected fields and loads relationships" do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Gone", view_count: 3, author_id: author.id})

    assert %{"success" => true, "data" => data} =
             AshRpc.run_action(@profile, ctx(), %{
               "action" => "destroy_post",
               "identity" => post.id,
               "fields" => ["title", %{"author" => ["name"]}]
             })

    assert data == %{"title" => "Gone", "author" => %{"name" => "Ada"}}
  end

  describe "vector attributes" do
    defp create_account(input, fields) do
      AshRpc.run_action(@profile, ctx(), %{
        "action" => "create_account",
        "input" => Map.put_new(input, "handle", "vector-#{System.unique_integer([:positive])}"),
        "fields" => fields
      })
    end

    test "a created vector comes back as a list of floats" do
      assert %{"success" => true, "data" => data} =
               create_account(%{"handle" => "ada", "embedding" => [1.0, 2.0, 3.0]}, [
                 "id",
                 "handle",
                 "embedding"
               ])

      assert data["handle"] == "ada"
      assert data["embedding"] == [1.0, 2.0, 3.0]
    end

    test "a vector in the response is JSON-encodable" do
      # Regression: `%Ash.Vector{}` holds its floats in a packed binary. Leaking
      # the struct made the response fail to encode with
      # `Jason.EncodeError: invalid byte 0x80`.
      result = create_account(%{"embedding" => [0.5, -1.5, 2.25]}, ["id", "embedding"])

      assert %{"success" => true, "data" => %{"embedding" => [0.5, -1.5, 2.25]}} = result
      assert {:ok, json} = Jason.encode(result)
      assert json =~ "0.5"
      assert json =~ "-1.5"
      assert json =~ "2.25"
    end

    test "a missing vector comes back as nil" do
      assert %{"success" => true, "data" => data} =
               create_account(%{}, ["id", "handle", "embedding"])

      assert Map.has_key?(data, "embedding")
      assert is_nil(data["embedding"])
    end

    test "a list action returns vectors as lists" do
      assert %{"success" => true} =
               create_account(%{"handle" => "listed", "embedding" => [4.0, 5.0, 6.0]}, ["id"])

      assert %{"success" => true, "data" => accounts} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "list_accounts",
                 "fields" => ["handle", "embedding"]
               })

      assert Enum.any?(accounts, fn account ->
               account["handle"] == "listed" and account["embedding"] == [4.0, 5.0, 6.0]
             end)

      assert {:ok, _json} = Jason.encode(accounts)
    end

    test "a vector that violates the dimensions constraint is a wire error" do
      assert %{"success" => false, "errors" => [error]} =
               create_account(%{"embedding" => [1.0, 2.0]}, ["id", "embedding"])

      assert %{"type" => "invalid_attribute", "fields" => ["embedding"]} = error
    end
  end

  describe "required fields param on a list read" do
    test "a list run without fields is missing_required_parameter for fields" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "missing_required_parameter",
                   "message" => "Required parameter %{parameter} is missing or empty",
                   "vars" => %{"parameter" => "fields"},
                   "path" => [],
                   "fields" => []
                 }
               ]
             } = AshRpc.run_action(@profile, ctx(), %{"action" => "list_posts"})
    end

    test "a list run with an empty fields list is empty_fields_array without a hint" do
      assert parse(%{"action" => "list_posts", "fields" => []}) ==
               {:error, {:empty_fields_array, []}}

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "empty_fields_array",
                   "vars" => %{},
                   "path" => [],
                   "fields" => [],
                   "details" => details
                 }
               ]
             } = AshRpc.run_action(@profile, ctx(), %{"action" => "list_posts", "fields" => []})

      assert details == %{"suggestion" => "Provide at least one field name in the fields array"}
    end
  end

  describe "malformed field entries" do
    test "a non-string field is invalid_field_type, reported as unknown_field" do
      params = %{"action" => "list_posts", "fields" => [123]}

      assert parse(params) == {:error, {:invalid_field_type, 123, []}}

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unknown_field",
                   "vars" => %{"field" => "123"},
                   "path" => [],
                   "fields" => ["123"]
                 }
               ]
             } = AshRpc.run_action(@profile, ctx(), params)
    end

    test "a relationship given a string spec is unsupported_field_combination" do
      params = %{"action" => "list_posts", "fields" => [%{"author" => "invalid_spec"}]}

      assert parse(params) ==
               {:error,
                {:unsupported_field_combination, :relationship, :author, "invalid_spec", []}}

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unsupported_field_combination",
                   "vars" => %{"field" => "author", "fieldType" => "relationship"},
                   "path" => [],
                   "fields" => ["author"],
                   "details" => %{"fieldSpec" => "\"invalid_spec\""}
                 }
               ]
             } = AshRpc.run_action(@profile, ctx(), params)
    end
  end

  describe "page param format" do
    test "a non-map page is invalid_pagination with the received value and no hint" do
      params = %{"action" => "list_comments", "fields" => ["body"], "page" => "invalid"}

      assert parse(params) == {:error, {:invalid_pagination, "invalid"}}

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_pagination",
                   "vars" => %{"received" => "\"invalid\""},
                   "path" => [],
                   "fields" => [],
                   "details" => details
                 }
               ]
             } = AshRpc.run_action(@profile, ctx(), params)

      assert details == %{
               "expected" => "Map with pagination parameters (limit, offset, before, after, etc.)"
             }
    end

    test "a negative page limit is invalid_page on the page path" do
      assert AshRpc.run_action(@profile, ctx(), %{
               "action" => "list_comments",
               "fields" => ["body"],
               "page" => %{"limit" => -5}
             }) == %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_page",
                   "message" => "[limit: -5] is not a valid page option",
                   "shortMessage" => "Invalid pagination",
                   "vars" => %{},
                   "path" => ["page"],
                   "fields" => []
                 }
               ]
             }
    end

    test "an unknown top-level page key under camelCase is invalid_pagination with the key as sent" do
      params = %{
        "action" => "list_posts",
        "fields" => ["id"],
        "page" => %{"limit" => 1, "page_size" => 2}
      }

      assert {:error, {:unknown_page_keys, ["page_size"]}} = parse(params)

      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), params)

      assert %{"fields" => ["page_size"], "vars" => %{"keys" => "page_size"}} = error
    end

    test "a page key in a non-client casing is an unknown key reported as sent" do
      # "Limit" used to lenient-parse to :limit and "pageSize" was reported as "page_size"
      assert {:error, {:unknown_page_keys, ["Limit", "pageSize"]}} =
               parse(%{
                 "action" => "list_posts",
                 "fields" => ["id"],
                 "page" => %{"Limit" => 1, "pageSize" => 2}
               })
    end
  end

  # Each shape used to crash (unknown_error / internal_error) or be ignored.
  describe "malformed request params" do
    defp only_error(params) do
      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), params)

      error
    end

    test "a getBy that is not a map is invalid_get_by" do
      for get_by <- ["alpha", ["alpha"], 5] do
        params = %{"action" => "get_post_by_slug", "getBy" => get_by, "fields" => ["id"]}

        assert parse(params) == {:error, {:invalid_get_by_format, get_by}}

        assert only_error(params) == %{
                 "type" => "invalid_get_by",
                 "message" => "getBy parameter must be a map",
                 "shortMessage" => "Invalid getBy value",
                 "vars" => %{"received" => inspect(get_by)},
                 "path" => ["getBy"],
                 "fields" => [],
                 "details" => %{"expected" => "Map of getBy field names to values"}
               }
      end
    end

    test "fields that is not a list is invalid_fields_type on a mutation" do
      for fields <- ["title", %{"title" => true}] do
        params = %{"action" => "create_post", "input" => %{"title" => "t"}, "fields" => fields}

        assert parse(params) == {:error, {:invalid_fields_type, fields}}

        assert %{
                 "type" => "invalid_fields_type",
                 "message" => "Fields parameter must be an array",
                 "vars" => %{"received" => received},
                 "path" => []
               } = only_error(params)

        assert received == inspect(fields)
      end
    end

    test "fields that is not a list is invalid_fields_type in validate_action" do
      assert %{"success" => false, "errors" => [%{"type" => "invalid_fields_type"}]} =
               AshRpc.validate_action(@profile, ctx(), %{
                 "action" => "create_post",
                 "input" => %{"title" => "t"},
                 "fields" => "title"
               })
    end

    test "metadataFields that is not a list is invalid_metadata_fields_type" do
      for {action, extra} <- [
            {"read_posts_with_metadata", %{"fields" => ["id"]}},
            {"create_post_with_metadata", %{"input" => %{"title" => "t"}}}
          ],
          metadata_fields <- ["totalScore", %{}] do
        params = Map.merge(extra, %{"action" => action, "metadataFields" => metadata_fields})

        assert parse(params) == {:error, {:invalid_metadata_fields_type, metadata_fields}}

        assert only_error(params) == %{
                 "type" => "invalid_metadata_fields_type",
                 "message" => "metadataFields parameter must be an array",
                 "shortMessage" => "Invalid metadataFields type",
                 "vars" => %{"received" => inspect(metadata_fields)},
                 "path" => ["metadataFields"],
                 "fields" => [],
                 "details" => %{"expected" => "Array of metadata field names"}
               }
      end
    end

    test "an action that is not a string is invalid_action_type" do
      for action <- [123, ["list_posts"], %{"name" => "list_posts"}] do
        params = %{"action" => action, "fields" => ["id"]}

        assert parse(params) == {:error, {:invalid_action_type, action}}

        expected = %{
          "type" => "invalid_action_type",
          "message" => "action parameter must be a string",
          "shortMessage" => "Invalid action type",
          "vars" => %{"received" => inspect(action)},
          "path" => ["action"],
          "fields" => [],
          "details" => %{"expected" => "The name of an RPC action"}
        }

        assert only_error(params) == expected

        assert %{"success" => false, "errors" => [^expected]} =
                 AshRpc.validate_action(@profile, ctx(), params)
      end
    end

    test "path and message use the formatted action key" do
      manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)

      assert %{"Success" => false, "Errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), %{"Action" => 5}, manifest: manifest)

      assert %{
               "Type" => "invalid_action_type",
               "Message" => "Action parameter must be a string",
               "Path" => ["Action"]
             } = error
    end

    test "a metadataFields list still resolves" do
      assert %{"success" => true} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "read_posts_with_metadata",
                 "metadataFields" => ["totalScore"],
                 "fields" => ["id"]
               })
    end
  end

  describe "strict input keys" do
    test "a snake_case input key under camelCase is unknown_input with the stale-client hint" do
      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "create_post",
                 "input" => %{"title" => "x", "view_count" => 1},
                 "fields" => ["id"]
               })

      assert %{"type" => "unknown_input", "fields" => ["view_count"], "details" => %{"hint" => _}} =
               error
    end

    test "each unknown key is its own error" do
      assert %{"success" => false, "errors" => errors} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "create_post",
                 "input" => %{"title" => "x", "bogusA" => 1, "bogusB" => 2},
                 "fields" => ["id"]
               })

      assert errors |> Enum.map(& &1["fields"]) |> Enum.sort() == [["bogusA"], ["bogusB"]]
    end

    test "the same keys succeed under snake_case" do
      manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :snake_case)

      assert %{"success" => true, "data" => %{"view_count" => 1}} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "action" => "create_post",
                   "input" => %{"title" => "x", "view_count" => 1},
                   "fields" => ["view_count"]
                 },
                 manifest: manifest
               )
    end
  end

  describe "select/load split" do
    test "the parsed request carries the split with calculation args in internal names" do
      assert {:ok, request} =
               parse(%{
                 "action" => "list_posts",
                 "fields" => [
                   "id",
                   "viewCount",
                   %{"author" => ["name"]},
                   %{"excerpt" => %{"args" => %{"length" => 3}}}
                 ]
               })

      assert request.resource == AshRpc.Test.Post
      assert request.action.name == :read
      assert request.select == [:id, :view_count]
      assert request.load == [{:author, [:name]}, {:excerpt, %{length: 3}}]
    end
  end

  describe "mutations without fields" do
    # A create or update runs and persists without a field selection; the
    # response data is then an empty map.
    for {label, fields} <- [{"no fields param", :omit}, {"an empty fields list", []}] do
      @fields fields

      test "a create with #{label} persists and returns empty data" do
        params =
          with_fields(%{"action" => "create_post", "input" => %{"title" => "quiet"}}, @fields)

        assert AshRpc.run_action(@profile, ctx(), params) == %{"success" => true, "data" => %{}}
        assert [%{title: "quiet"}] = Ash.read!(AshRpc.Test.Post)
      end

      test "an update with #{label} persists and returns empty data" do
        post = Ash.create!(AshRpc.Test.Post, %{title: "before"})

        params =
          with_fields(
            %{"action" => "update_post", "identity" => post.id, "input" => %{"title" => "after"}},
            @fields
          )

        assert AshRpc.run_action(@profile, ctx(), params) == %{"success" => true, "data" => %{}}
        assert Ash.get!(AshRpc.Test.Post, post.id).title == "after"
      end
    end
  end

  # Bookmark names no domain of its own; each action gets the entrypoint's.
  describe "a resource without a domain of its own" do
    defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

    defp seed_bookmark(url), do: Ash.Seed.seed!(AshRpc.Test.Bookmark, %{url: url}).id

    test "create" do
      assert %{"success" => true, "data" => %{"url" => "https://a.test"}} =
               run(%{
                 "action" => "create_bookmark",
                 "input" => %{"url" => "https://a.test"},
                 "fields" => ["url"]
               })
    end

    test "read" do
      seed_bookmark("https://a.test")

      assert %{"success" => true, "data" => [%{"url" => "https://a.test"}]} =
               run(%{"action" => "list_bookmarks", "fields" => ["url"]})
    end

    test "update and destroy" do
      id = seed_bookmark("https://a.test")

      assert %{"success" => true, "data" => %{"url" => "https://b.test"}} =
               run(%{
                 "action" => "update_bookmark",
                 "identity" => id,
                 "input" => %{"url" => "https://b.test"},
                 "fields" => ["url"]
               })

      assert %{"success" => true} = run(%{"action" => "destroy_bookmark", "identity" => id})
    end

    test "generic action" do
      assert %{"success" => true, "data" => "hi"} =
               run(%{"action" => "echo_bookmark", "input" => %{"text" => "hi"}})
    end
  end
end
