# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ValidationTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile
  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)
  defp validate(params), do: AshRpc.validate_action(@profile, ctx(), params)

  test "create: a missing required attribute is a native 'required' error" do
    assert %{"success" => false, "errors" => errors} =
             validate(%{"action" => "create_post", "input" => %{}})

    assert Enum.any?(errors, &(&1["type"] == "required" and &1["fields"] == ["title"]))
  end

  test "create: nothing is persisted" do
    assert %{"success" => true} =
             validate(%{"action" => "create_post", "input" => %{"title" => "x"}})

    assert %{"data" => []} = run(%{"action" => "list_posts", "fields" => ["id"]})
  end

  test "read: valid input succeeds" do
    assert %{"success" => true} = validate(%{"action" => "list_posts"})
  end

  test "generic action: a missing argument is required under its client name" do
    assert validate(%{"action" => "word_count", "input" => %{}}) == %{
             "success" => false,
             "errors" => [
               %{
                 "type" => "required",
                 "message" => "argument %{field} is required",
                 "shortMessage" => "Required field",
                 "fields" => ["body"],
                 "path" => [],
                 "vars" => %{"field" => "body"}
               }
             ]
           }
  end

  test "update: unknown identity is not_found" do
    assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
             validate(%{
               "action" => "update_post",
               "identity" => Ash.UUID.generate(),
               "input" => %{"title" => "y"}
             })
  end

  test "update/destroy: an existing record validates and stays unchanged" do
    %{"data" => %{"id" => id}} =
      run(%{"action" => "create_post", "input" => %{"title" => "a"}, "fields" => ["id"]})

    assert %{"success" => true} =
             validate(%{
               "action" => "update_post",
               "identity" => id,
               "input" => %{"title" => "b"}
             })

    assert %{"success" => true} = validate(%{"action" => "destroy_post", "identity" => id})

    assert %{"data" => [%{"title" => "a"}]} =
             run(%{"action" => "list_posts", "fields" => ["title"]})
  end

  @tag :capture_log
  test "the read_action used for the lookup is the entrypoint's" do
    manifest = AshRpc.Test.ManifestBuilder.manifest()

    entrypoint = %{
      AshRpc.Manifest.entrypoint_lookup(manifest)["update_post"]
      | read_action: :no_such_read
    }

    %{"data" => %{"id" => id}} =
      run(%{"action" => "create_post", "input" => %{"title" => "a"}, "fields" => ["id"]})

    assert %{"success" => false} =
             AshRpc.validate_action(@profile, ctx(), %{"identity" => id, "input" => %{}},
               entrypoint: entrypoint
             )
  end

  test "a record the entrypoint's read_action hides is not_found for validate and run" do
    hidden = Ash.create!(AshRpc.Test.Post, %{title: "Hidden", view_count: 5})

    validate =
      validate(%{
        "action" => "update_post_scoped",
        "identity" => hidden.id,
        "input" => %{"title" => "probe"}
      })

    run =
      run(%{
        "action" => "update_post_scoped",
        "identity" => hidden.id,
        "input" => %{"title" => "probe"},
        "fields" => ["id"]
      })

    assert %{"success" => false, "errors" => [%{"type" => "not_found"} | _]} = validate
    assert %{"success" => false, "errors" => [%{"type" => "not_found"} | _]} = run
    assert Ash.get!(AshRpc.Test.Post, hidden.id).title == "Hidden"
  end

  test "a record the entrypoint's read_action admits validates and updates" do
    visible = Ash.create!(AshRpc.Test.Post, %{title: "Visible"})

    assert %{"success" => true} =
             validate(%{
               "action" => "update_post_scoped",
               "identity" => visible.id,
               "input" => %{"title" => "new title"}
             })

    assert %{"success" => true, "data" => %{"title" => "new title"}} =
             run(%{
               "action" => "update_post_scoped",
               "identity" => visible.id,
               "input" => %{"title" => "new title"},
               "fields" => ["title"]
             })
  end

  @owner_id "550e8400-e29b-41d4-a716-446655440000"

  defp required_error(field, message) do
    %{
      "type" => "required",
      "message" => message,
      "shortMessage" => "Required field",
      "vars" => %{"field" => field},
      "fields" => [field],
      "path" => []
    }
  end

  defp invalid_error("invalid_attribute", field),
    do: invalid_error("invalid_attribute", "Invalid attribute", field)

  defp invalid_error("invalid_argument", field),
    do: invalid_error("invalid_argument", "Invalid argument", field)

  defp invalid_error(type, short, field) do
    %{
      "type" => type,
      "message" => "is invalid",
      "shortMessage" => short,
      "vars" => %{"field" => field},
      "fields" => [field],
      "path" => []
    }
  end

  defp sorted(errors), do: Enum.sort_by(errors, & &1["fields"])

  describe "required input errors" do
    test "a missing required attribute names the attribute in message, vars and fields" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{
                 "action" => "create_post_for_owner",
                 "input" => %{"ownerId" => @owner_id}
               })

      assert errors == [required_error("title", "attribute %{field} is required")]
    end

    test "a missing multi-word argument reports its client name in vars and fields" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{"action" => "create_post_for_owner", "input" => %{"title" => "Post"}})

      assert errors == [required_error("ownerId", "argument %{field} is required")]
    end

    test "every missing required input gets its own error" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{"action" => "create_post_for_owner", "input" => %{}})

      assert sorted(errors) == [
               required_error("ownerId", "argument %{field} is required"),
               required_error("title", "attribute %{field} is required")
             ]
    end
  end

  describe "invalid input casts" do
    test "a bad attribute cast on a create is invalid_attribute" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{
                 "action" => "create_post_for_owner",
                 "input" => %{"title" => 123, "ownerId" => @owner_id}
               })

      assert errors == [invalid_error("invalid_attribute", "title")]
    end

    test "a bad multi-word argument cast on a create is invalid_argument with its client name" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{
                 "action" => "create_post_for_owner",
                 "input" => %{"title" => "Post", "ownerId" => 12_345}
               })

      assert errors == [invalid_error("invalid_argument", "ownerId")]
    end

    test "a value outside an atom attribute's one_of is invalid_attribute" do
      assert %{"success" => true} =
               validate(%{"action" => "create_project", "input" => %{"priority" => "high"}})

      assert %{"success" => false, "errors" => errors} =
               validate(%{
                 "action" => "create_project",
                 "input" => %{"priority" => "invalid_priority"}
               })

      assert errors == [invalid_error("invalid_attribute", "priority")]
    end

    test "a bad read-argument value is invalid_argument with an empty path" do
      assert %{"success" => true} =
               validate(%{
                 "action" => "list_rated_comments_no_filter_no_sort",
                 "input" => %{"minRating" => 3}
               })

      assert %{"success" => false, "errors" => errors} =
               validate(%{
                 "action" => "list_rated_comments_no_filter_no_sort",
                 "input" => %{"minRating" => "not a number"}
               })

      assert errors == [invalid_error("invalid_argument", "minRating")]
    end

    test "a missing required read argument is required" do
      assert %{"success" => true} =
               validate(%{
                 "action" => "search_intakes",
                 "input" => %{"query" => "a", "includeDeleted" => true, "filterBy1" => false}
               })

      assert %{"success" => false, "errors" => errors} =
               validate(%{"action" => "search_intakes", "input" => %{"includeDeleted" => true}})

      assert errors == [required_error("query", "argument %{field} is required")]
    end
  end

  describe "error structure" do
    test "different failures on one request are all reported" do
      assert %{"success" => false, "errors" => errors} =
               validate(%{"action" => "create_post_for_owner", "input" => %{"title" => 123}})

      assert sorted(errors) == [
               required_error("ownerId", "argument %{field} is required"),
               invalid_error("invalid_attribute", "title")
             ]
    end

    test "a successful validation has no errors key" do
      assert validate(%{
               "action" => "create_post_for_owner",
               "input" => %{"title" => "Post", "ownerId" => @owner_id}
             }) == %{"success" => true}
    end

    test "validate_action and run_action report the same errors for a bad input" do
      params = %{
        "action" => "create_post_for_owner",
        "input" => %{"title" => 123, "ownerId" => @owner_id}
      }

      assert %{"success" => false, "errors" => validate_errors} = validate(params)

      assert %{"success" => false, "errors" => run_errors} =
               run(Map.put(params, "fields", ["id"]))

      assert validate_errors == [invalid_error("invalid_attribute", "title")]
      assert run_errors == validate_errors
    end
  end

  describe "field selection" do
    test "a typed-map generic action validates without fields and runs with them" do
      assert validate(%{"action" => "totals"}) == %{"success" => true}

      assert run(%{"action" => "totals", "fields" => ["total"]}) ==
               %{"success" => true, "data" => %{"total" => 2}}
    end

    test "validate_action checks requested fields when they are given" do
      assert validate(%{"action" => "list_posts", "fields" => ["id", "title"]}) ==
               %{"success" => true}

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unknown_field",
                   "vars" => %{"field" => "unknownField", "resource" => "AshRpc.Test.Post"},
                   "path" => [],
                   "fields" => ["unknownField"]
                 }
               ]
             } = validate(%{"action" => "list_posts", "fields" => ["id", "unknown_field"]})
    end
  end
end
