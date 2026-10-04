# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.GetActionsTest do
  use ExUnit.Case, async: true

  alias AshRpc.Test.{Author, Comment, Post}

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params, context \\ ctx()), do: AshRpc.run_action(@profile, context, params)

  defp parse(params),
    do: AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Author's `name_active` identity is enforced on ETS, so every author gets a unique name.
  defp author!(attrs \\ %{}), do: Ash.create!(Author, Map.put_new(attrs, :name, unique("author")))

  defp post!(attrs), do: Ash.create!(Post, Map.put_new(attrs, :title, "Post"))

  defp reload!(%resource{id: id}), do: Ash.get!(resource, id)

  describe "get? entrypoint" do
    test "returns a single map with relationship, calculation and aggregate fields" do
      author = author!()
      post = post!(%{title: "Hello world", author_id: author.id})
      Ash.create!(Comment, %{body: "first", post_id: post.id})

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "get_post",
                 "fields" => [
                   "id",
                   "title",
                   %{"author" => ["name"]},
                   "titleLength",
                   "commentCount",
                   "hasComments"
                 ]
               })

      assert data == %{
               "id" => post.id,
               "title" => "Hello world",
               "author" => %{"name" => author.name},
               "titleLength" => 11,
               "commentCount" => 1,
               "hasComments" => true
             }
    end

    test "no record is not_found" do
      assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
               run(%{"action" => "get_post", "fields" => ["id"]})
    end
  end

  describe "getBy" do
    test "a single getBy field selects the matching record" do
      post = post!(%{title: "Wanted", slug: unique("wanted")})
      post!(%{title: "Other", slug: unique("other")})

      assert %{"success" => true, "data" => %{"id" => id, "title" => "Wanted"}} =
               run(%{
                 "action" => "get_post_by_slug",
                 "getBy" => %{"slug" => post.slug},
                 "fields" => ["id", "title"]
               })

      assert id == post.id
    end

    test "a composite getBy matches on every field" do
      slug = unique("composite")
      wanted = post!(%{title: "A", slug: slug})
      post!(%{title: "B", slug: unique("composite")})

      assert %{"success" => true, "data" => %{"id" => id, "title" => "A"}} =
               run(%{
                 "action" => "get_post_by_slug_and_title",
                 "getBy" => %{"slug" => slug, "title" => "A"},
                 "fields" => ["id", "title"]
               })

      assert id == wanted.id
    end

    test "no match is not_found" do
      post!(%{slug: unique("present")})

      assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
               run(%{
                 "action" => "get_post_by_slug",
                 "getBy" => %{"slug" => unique("absent")},
                 "fields" => ["id"]
               })
    end

    test "a missing getBy key is missing_required_input" do
      params = %{
        "action" => "get_post_by_slug_and_title",
        "getBy" => %{"slug" => unique("partial")},
        "fields" => ["id"]
      }

      assert {:error, {:missing_get_by_fields, ["title"]}} = parse(params)

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "missing_required_input",
                   "shortMessage" => "Missing required getBy fields",
                   "vars" => %{"fields" => "title"},
                   "fields" => ["title"],
                   "path" => [:get_by]
                 }
               ]
             } = run(params)
    end

    test "an unexpected getBy key is unexpected_get_by_fields" do
      params = %{
        "action" => "get_post_by_slug",
        "getBy" => %{"slug" => unique("extra"), "title" => "x"},
        "fields" => ["id"]
      }

      assert {:error, {:unexpected_get_by_fields, ["title"], ["slug"]}} = parse(params)

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unexpected_get_by_fields",
                   "fields" => ["title"],
                   "details" => %{"allowedFields" => ["slug"]}
                 }
               ]
             } = run(params)
    end
  end

  describe "not_found_error?: false" do
    test "no match is success with data nil" do
      # A nil read_one result passes process_result/format_output as nil data
      assert %{"success" => true, "data" => nil} =
               run(%{
                 "action" => "get_post_by_slug_nullable",
                 "getBy" => %{"slug" => unique("absent")},
                 "fields" => ["id"]
               })
    end

    test "a match still returns the record" do
      post = post!(%{title: "Found", slug: unique("found")})

      assert %{"success" => true, "data" => %{"title" => "Found"}} =
               run(%{
                 "action" => "get_post_by_slug_nullable",
                 "getBy" => %{"slug" => post.slug},
                 "fields" => ["title"]
               })
    end
  end

  describe "validate_action" do
    test "a get? entrypoint validates without input" do
      assert %{"success" => true} =
               AshRpc.validate_action(@profile, ctx(), %{"action" => "get_post"})
    end

    test "a getBy entrypoint validates with getBy" do
      assert %{"success" => true} =
               AshRpc.validate_action(@profile, ctx(), %{
                 "action" => "get_post_by_slug",
                 "getBy" => %{"slug" => "any"}
               })
    end

    test "a getBy entrypoint fails validation without getBy" do
      assert %{
               "success" => false,
               "errors" => [%{"type" => "missing_required_input", "fields" => ["slug"]}]
             } = AshRpc.validate_action(@profile, ctx(), %{"action" => "get_post_by_slug"})
    end
  end

  describe "identities" do
    test "the primary key is passed as a scalar" do
      author = author!()
      new_name = unique("renamed")

      assert %{"success" => true, "data" => %{"name" => ^new_name}} =
               run(%{
                 "action" => "update_author",
                 "identity" => author.id,
                 "input" => %{"name" => new_name},
                 "fields" => ["name"]
               })
    end

    test "a named identity is passed as a map with client field names" do
      author = author!()
      new_name = unique("renamed")

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "update_author_by_identity",
                 "identity" => %{"name" => author.name, "isActive" => true},
                 "input" => %{"name" => new_name},
                 "fields" => ["id", "name", "isActive"]
               })

      assert data == %{"id" => author.id, "name" => new_name, "isActive" => true}
    end

    test "extra identity keys are ignored" do
      post = post!(%{title: "Before", slug: unique("extra")})

      assert %{"success" => true, "data" => %{"title" => "After"}} =
               run(%{
                 "action" => "update_post_by_slug",
                 "identity" => %{"slug" => post.slug, "extraField" => "value"},
                 "input" => %{"title" => "After"},
                 "fields" => ["title"]
               })
    end

    test "a non-matching identity value is not_found and changes nothing" do
      post = post!(%{title: "Before", slug: unique("kept")})

      # An empty bulk_update result maps to Ash.Error.Query.NotFound
      assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
               run(%{
                 "action" => "update_post_by_slug",
                 "identity" => %{"slug" => unique("missing")},
                 "input" => %{"title" => "After"},
                 "fields" => ["title"]
               })

      assert reload!(post).title == "Before"
    end

    test "a scalar identity is invalid_identity when the primary key is not allowed" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_identity",
                   "message" => "Primary key identity not allowed for this action",
                   "shortMessage" => "Invalid identity",
                   "vars" => vars,
                   "path" => [:identity]
                 }
               ]
             } =
               run(%{
                 "action" => "update_post_by_slug",
                 "identity" => "some-slug",
                 "input" => %{"title" => "After"},
                 "fields" => ["title"]
               })

      assert vars == %{}
    end

    test "invalid_identity reports provided and expected keys with client names" do
      author = author!()

      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "update_author_by_identity",
                 "identity" => %{"name" => author.name, "isActiv" => true},
                 "input" => %{"name" => unique("renamed")},
                 "fields" => ["id"]
               })

      assert %{
               "type" => "invalid_identity",
               "shortMessage" => "Invalid identity",
               "path" => [:identity],
               "vars" => %{"expectedKeys" => "id, name, isActive", "providedKeys" => provided},
               "details" => %{
                 "expectedKeys" => ["id", "name", "isActive"],
                 "providedKeys" => keys
               }
             } = error

      assert error["message"] =~ "%{providedKeys}"
      assert error["message"] =~ "%{expectedKeys}"
      assert Enum.sort(keys) == ["isActiv", "name"]
      # Map key order puts the existing atom :name before the unresolved "is_activ"
      assert provided == "name, isActiv"
      assert reload!(author).name == author.name
    end

    test "an empty identity map is invalid_identity" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_identity",
                   "details" => %{"providedKeys" => [], "expectedKeys" => ["slug"]}
                 }
               ]
             } =
               run(%{
                 "action" => "update_post_by_slug",
                 "identity" => %{},
                 "input" => %{"title" => "After"},
                 "fields" => ["title"]
               })
    end
  end

  describe "missing_identity" do
    test "update without identity" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "missing_identity",
                   "shortMessage" => "Missing identity",
                   "message" => "Identity is required. Provide the id value directly.",
                   "path" => [:identity],
                   "details" => %{"expectedKeys" => ["id"]}
                 }
               ]
             } =
               run(%{
                 "action" => "update_author",
                 "input" => %{"name" => unique("renamed")},
                 "fields" => ["id"]
               })
    end

    test "destroy without identity" do
      author = author!()

      assert %{
               "success" => false,
               "errors" => [%{"type" => "missing_identity", "shortMessage" => "Missing identity"}]
             } = run(%{"action" => "destroy_author", "fields" => ["id"]})

      assert reload!(author).id == author.id
    end

    test "several identities list every expected key with client names" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "missing_identity",
                   "message" => message,
                   "vars" => %{"expectedKeys" => "id, name, isActive"}
                 }
               ]
             } =
               run(%{
                 "action" => "update_author_by_identity",
                 "input" => %{"name" => unique("renamed")},
                 "fields" => ["id"]
               })

      assert message =~ "Expected one of: [%{expectedKeys}]"
    end
  end

  describe "actor-scoped entrypoints" do
    test "update_me updates the actor without an identity" do
      actor = author!()
      other = author!()
      new_name = unique("me")

      # `bulk_update` applies read_action :me (filter id == ^actor(:id)) to the target query
      assert %{"success" => true, "data" => data} =
               run(
                 %{
                   "action" => "update_me",
                   "input" => %{"name" => new_name},
                   "fields" => ["id", "name"]
                 },
                 %AshRpc.Context{actor: actor}
               )

      assert data == %{"id" => actor.id, "name" => new_name}
      assert reload!(other).name == other.name
    end

    test "destroy_me destroys the actor without an identity" do
      actor = author!()
      other = author!()

      assert %{"success" => true, "data" => %{"id" => id}} =
               run(%{"action" => "destroy_me", "fields" => ["id"]}, %AshRpc.Context{actor: actor})

      assert id == actor.id
      assert {:error, _} = Ash.get(Author, actor.id)
      assert reload!(other).id == other.id
    end
  end

  describe "non-scalar lookup values" do
    test "an operator map as a getBy value is invalid_get_by" do
      # As a filter, %{"lessThan" => "b"} would select this record without naming it.
      post!(%{title: "Alpha", slug: unique("alpha")})

      params = %{
        "action" => "get_post_by_slug",
        "getBy" => %{"slug" => %{"lessThan" => "b"}},
        "fields" => ["id", "title"]
      }

      assert {:error, {:invalid_get_by, %{message: message}}} = parse(params)
      assert message =~ "Non-scalar value provided for: slug"

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_get_by",
                   "shortMessage" => "Invalid getBy value",
                   "path" => [:get_by]
                 }
               ]
             } = result = run(params)

      refute Map.has_key?(result, "data")
    end

    test "a list as a getBy value is invalid_get_by" do
      first = post!(%{slug: unique("first")})
      second = post!(%{slug: unique("second")})

      params = %{
        "action" => "get_post_by_slug",
        "getBy" => %{"slug" => [first.slug, second.slug]},
        "fields" => ["id"]
      }

      assert {:error, {:invalid_get_by, %{message: _}}} = parse(params)

      assert %{"success" => false, "errors" => [%{"type" => "invalid_get_by"}]} = run(params)
    end

    test "an operator map as an identity value is invalid_identity, record unchanged" do
      # As a filter, %{"greaterThan" => ""} would match (and update) every slugged post.
      post = post!(%{title: "Original", slug: unique("target")})

      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "invalid_identity",
                   "shortMessage" => "Invalid identity",
                   "message" => message,
                   "path" => [:identity]
                 }
               ]
             } =
               run(%{
                 "action" => "update_post_by_slug",
                 "identity" => %{"slug" => %{"greaterThan" => ""}},
                 "input" => %{"title" => "Injected"},
                 "fields" => ["title"]
               })

      assert message =~ "Non-scalar value provided for: slug"
      assert reload!(post).title == "Original"
    end

    test "a list as the primary key is invalid_identity, record unchanged" do
      post = post!(%{title: "Original"})

      assert %{
               "success" => false,
               "errors" => [%{"type" => "invalid_identity", "message" => message}]
             } =
               run(%{
                 "action" => "update_post",
                 "identity" => [post.id],
                 "input" => %{"title" => "Injected"},
                 "fields" => ["title"]
               })

      assert message =~ "Non-scalar value provided for: id"
      assert reload!(post).title == "Original"
    end
  end
end
