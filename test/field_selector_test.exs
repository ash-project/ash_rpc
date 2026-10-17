# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldSelectorTest do
  use ExUnit.Case, async: true

  alias AshRpc.{RequestedFieldsProcessor, Runtime}

  @profile AshRpc.Test.Profile

  defp run(action, fields),
    do: AshRpc.run_action(@profile, %AshRpc.Context{}, %{"action" => action, "fields" => fields})

  defp runtime, do: Runtime.new(@profile)

  defp process(resource, fields),
    do: RequestedFieldsProcessor.process(runtime(), resource, :read, fields)

  defp single_error(%{"success" => false, "errors" => [error]}), do: error

  # One author with one post titled "Hello" that has one comment.
  defp seed_graph do
    author = Ash.create!(AshRpc.Test.Author, %{name: "Ada-#{System.unique_integer([:positive])}"})
    post = Ash.create!(AshRpc.Test.Post, %{title: "Hello", author_id: author.id})
    comment = Ash.create!(AshRpc.Test.Comment, %{body: "first", rating: 4, post_id: post.id})
    %{author: author, post: post, comment: comment}
  end

  test "selects attributes and an exposed relationship" do
    fields =
      RequestedFieldsProcessor.atomize_requested_fields(
        ["id", "title", %{"author" => ["name", "isActive"]}],
        AshRpc.Test.Post,
        runtime()
      )

    assert {:ok, {select, load, _template}} = process(AshRpc.Test.Post, fields)

    assert :title in select
    assert [{:author, _}] = load
  end

  test "a relationship to an unexposed resource is unknown_field" do
    fields =
      RequestedFieldsProcessor.atomize_requested_fields(
        [%{"secret" => ["code"]}],
        AshRpc.Test.Post,
        runtime()
      )

    assert {:error, {:unknown_field, :secret, AshRpc.Test.Post, _path}} =
             process(AshRpc.Test.Post, fields)
  end

  test "a calculation returning a resource is loaded with empty args and its nested fields" do
    assert {:ok, {[:id], [{:self_post, {%{}, [:title]}}], [:id, {:self_post, [:title]}]}} =
             process(AshRpc.Test.Post, ["id", %{"selfPost" => ["title"]}])
  end

  describe "requires_field_selection on relationships" do
    test "a relationship requested by bare name" do
      assert {:error, {:requires_field_selection, :relationship, :author, []}} =
               process(AshRpc.Test.Post, ["id", "author"])

      assert %{
               "type" => "requires_field_selection",
               "fields" => ["author"],
               "path" => [],
               "vars" => %{"field" => "author", "fieldType" => "Relationship"}
             } = single_error(run("list_posts", ["id", "author"]))
    end

    test "a relationship with an empty field list, to-one and to-many" do
      for {name, internal} <- [{"author", :author}, {"comments", :comments}] do
        assert {:error, {:requires_field_selection, :relationship, ^internal, []}} =
                 process(AshRpc.Test.Post, ["id", %{name => []}])

        assert %{
                 "type" => "requires_field_selection",
                 "fields" => [^name],
                 "path" => [],
                 "vars" => %{"field" => ^name, "fieldType" => "Relationship"}
               } = single_error(run("list_posts", ["id", %{name => []}]))
      end
    end
  end

  describe "duplicate_field" do
    test "a repeated attribute or aggregate, at the top level and inside a relationship" do
      assert {:error, {:duplicate_field, :id, []}} =
               process(AshRpc.Test.Post, ["id", "title", "id"])

      assert {:error, {:duplicate_field, :comment_count, []}} =
               process(AshRpc.Test.Post, ["commentCount", "commentCount"])

      error = single_error(run("list_posts", ["id", "title", "id"]))

      assert %{
               "type" => "duplicate_field",
               "fields" => ["id"],
               "path" => [],
               "vars" => %{"field" => "id"},
               "message" => "Field %{field} was requested multiple times"
             } = error

      assert error["details"] == %{"suggestion" => "Remove duplicate field specifications"}

      assert %{
               "type" => "duplicate_field",
               "fields" => ["commentCount"],
               "vars" => %{"field" => "commentCount"}
             } = single_error(run("list_posts", ["commentCount", "commentCount"]))

      assert %{
               "type" => "duplicate_field",
               "fields" => ["author.name"],
               "path" => ["author"]
             } = single_error(run("list_posts", [%{"author" => ["name", "name"]}]))
    end

    test "a repeated relationship" do
      fields = [%{"author" => ["id", "name"]}, %{"author" => ["isActive"]}]

      assert {:error, {:duplicate_field, :author, []}} = process(AshRpc.Test.Post, fields)

      error = single_error(run("list_posts", fields))

      assert %{
               "type" => "duplicate_field",
               "fields" => ["author"],
               "path" => [],
               "vars" => %{"field" => "author"}
             } = error

      assert error["details"] == %{"suggestion" => "Remove duplicate field specifications"}
    end

    test "a bare name and a map for the same calculation or aggregate" do
      calc = ["titleLength", %{"titleLength" => %{"args" => %{}}}]
      aggregate = ["commentCount", %{"commentCount" => []}]

      assert {:error, {:duplicate_field, :title_length, []}} = process(AshRpc.Test.Post, calc)

      assert {:error, {:duplicate_field, :comment_count, []}} =
               process(AshRpc.Test.Post, aggregate)

      assert %{"type" => "duplicate_field", "fields" => ["titleLength"], "path" => []} =
               single_error(run("list_posts", calc))

      assert %{"type" => "duplicate_field", "fields" => ["commentCount"], "path" => []} =
               single_error(run("list_posts", aggregate))
    end
  end

  test "field_does_not_support_nesting: a nested list on a plain attribute" do
    assert {:error, {:field_does_not_support_nesting, :title, []}} =
             process(AshRpc.Test.Post, [%{"title" => ["invalid"]}])

    assert %{
             "type" => "field_does_not_support_nesting",
             "fields" => ["title"],
             "path" => [],
             "vars" => %{"field" => "title"}
           } = single_error(run("list_posts", [%{"title" => ["invalid"]}]))
  end

  describe "deeply nested relationships" do
    setup do
      seed_graph()
    end

    test "three levels of nested relationships", %{author: author, post: post, comment: comment} do
      fields = [
        "id",
        "name",
        %{
          "posts" => [
            "id",
            "title",
            %{"comments" => ["id", "body", %{"post" => ["id", "title"]}]}
          ]
        }
      ]

      assert {:ok, {select, load, template}} = process(AshRpc.Test.Author, fields)
      assert select == [:id, :name]
      assert load == [posts: [:id, :title, comments: [:id, :body, post: [:id, :title]]]]

      assert template == [
               :id,
               :name,
               posts: [:id, :title, comments: [:id, :body, post: [:id, :title]]]
             ]

      assert %{"success" => true, "data" => data} = run("list_authors", fields)

      assert data == [
               %{
                 "id" => author.id,
                 "name" => author.name,
                 "posts" => [
                   %{
                     "id" => post.id,
                     "title" => "Hello",
                     "comments" => [
                       %{
                         "id" => comment.id,
                         "body" => "first",
                         "post" => %{"id" => post.id, "title" => "Hello"}
                       }
                     ]
                   }
                 ]
               }
             ]
    end

    test "nested relationships in several branches of one map", %{
      author: author,
      post: post,
      comment: comment
    } do
      fields = [
        "id",
        "title",
        %{
          "author" => ["id", "name", %{"posts" => ["id", "title"]}],
          "comments" => ["id", "rating", %{"post" => ["id", "slug"]}]
        }
      ]

      assert {:ok, {select, load, template}} = process(AshRpc.Test.Post, fields)
      assert select == [:id, :title]

      assert load == [
               author: [:id, :name, posts: [:id, :title]],
               comments: [:id, :rating, post: [:id, :slug]]
             ]

      assert template == [
               :id,
               :title,
               author: [:id, :name, posts: [:id, :title]],
               comments: [:id, :rating, post: [:id, :slug]]
             ]

      assert %{"success" => true, "data" => data} = run("list_posts", fields)

      assert data == [
               %{
                 "id" => post.id,
                 "title" => "Hello",
                 "author" => %{
                   "id" => author.id,
                   "name" => author.name,
                   "posts" => [%{"id" => post.id, "title" => "Hello"}]
                 },
                 "comments" => [
                   %{
                     "id" => comment.id,
                     "rating" => 4,
                     "post" => %{"id" => post.id, "slug" => nil}
                   }
                 ]
               }
             ]
    end

    test "a relationship holding only a nested relationship", %{post: post} do
      fields = ["id", %{"author" => [%{"posts" => ["id", "title"]}]}]

      assert {:ok,
              {[:id], [author: [posts: [:id, :title]]], [:id, author: [posts: [:id, :title]]]}} =
               process(AshRpc.Test.Post, fields)

      assert %{"success" => true, "data" => data} = run("list_posts", fields)

      assert data == [
               %{
                 "id" => post.id,
                 "author" => %{"posts" => [%{"id" => post.id, "title" => "Hello"}]}
               }
             ]
    end

    test "attributes, calculations, aggregates and relationships in one selection", %{
      author: author,
      post: post,
      comment: comment
    } do
      fields = [
        "id",
        "title",
        "commentCount",
        %{"author" => ["id", "name"]},
        "titleLength",
        %{"comments" => ["id", "body"]},
        "slug"
      ]

      assert {:ok, {select, load, template}} = process(AshRpc.Test.Post, fields)
      assert select == [:id, :title, :slug]

      assert load == [
               :comment_count,
               {:author, [:id, :name]},
               :title_length,
               {:comments, [:id, :body]}
             ]

      assert template == [
               :id,
               :title,
               :comment_count,
               :title_length,
               :slug,
               author: [:id, :name],
               comments: [:id, :body]
             ]

      assert %{"success" => true, "data" => data} = run("list_posts", fields)

      assert data == [
               %{
                 "id" => post.id,
                 "title" => "Hello",
                 "commentCount" => 1,
                 "titleLength" => 5,
                 "slug" => nil,
                 "author" => %{"id" => author.id, "name" => author.name},
                 "comments" => [%{"id" => comment.id, "body" => "first"}]
               }
             ]
    end
  end

  describe "a calculation with arguments given a plain string" do
    test "is invalid_calculation_args, not a field list" do
      assert process(AshRpc.Test.Project, [%{"self" => "invalid_structure"}]) ==
               {:error, {:invalid_calculation_args, :self, []}}

      assert single_error(run("list_projects", [%{"self" => "invalid_structure"}])) == %{
               "type" => "invalid_calculation_args",
               "message" => "Invalid arguments for calculation %{field}",
               "shortMessage" => "Invalid calculation arguments",
               "fields" => ["self"],
               "path" => [],
               "vars" => %{"field" => "self"},
               "details" => %{
                 "expected" => "Map containing argument values or valid field selection format",
                 "hint" => AshRpc.Test.Profile.stale_client_hint()
               }
             }
    end
  end

  describe "unknown_field at depth" do
    test "an unknown attribute inside a relationship" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["author.invalidField"],
               "path" => ["author"],
               "vars" => %{"field" => "author.invalidField", "resource" => "AshRpc.Test.Author"}
             } = single_error(run("list_posts", [%{"author" => ["invalidField"]}]))
    end

    test "an unknown relationship inside a relationship" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["author.invalidRelationship"],
               "path" => ["author"],
               "vars" => %{"resource" => "AshRpc.Test.Author"}
             } =
               single_error(
                 run("list_posts", [%{"author" => [%{"invalidRelationship" => ["id"]}]}])
               )
    end

    test "an unknown field two relationships deep" do
      fields = [%{"author" => ["id", %{"posts" => ["id", "invalidField"]}]}]

      assert %{
               "type" => "unknown_field",
               "fields" => ["author.posts.invalidField"],
               "path" => ["author", "posts"],
               "vars" => %{"resource" => "AshRpc.Test.Post"}
             } = single_error(run("list_posts", fields))
    end

    test "an unknown field through a calculation and a relationship" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["selfPost.author.nope"],
               "path" => ["selfPost", "author"],
               "vars" => %{"resource" => "AshRpc.Test.Author"}
             } = single_error(run("list_posts", [%{"selfPost" => [%{"author" => ["nope"]}]}]))
    end

    test "an unknown relationship with a nested list is unknown_field" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["nonexistentRelation"],
               "path" => [],
               "vars" => %{"field" => "nonexistentRelation", "resource" => "AshRpc.Test.Post"}
             } = single_error(run("list_posts", [%{"nonexistentRelation" => ["id", "name"]}]))
    end
  end

  # `Post.title_shout` is public but `field? false`: it can't be selected.
  describe "a field? false calculation" do
    test "is unknown_field when selected by name" do
      assert {:error, {:unknown_field, :title_shout, AshRpc.Test.Post, []}} =
               process(AshRpc.Test.Post, [:title_shout])

      assert %{
               "type" => "unknown_field",
               "fields" => ["titleShout"],
               "path" => [],
               "vars" => %{"field" => "titleShout", "resource" => "AshRpc.Test.Post"}
             } = single_error(run("list_posts", ["id", "titleShout"]))
    end

    test "is unknown_field inside a relationship selection" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["author.posts.titleShout"],
               "path" => ["author", "posts"]
             } = single_error(run("list_posts", [%{"author" => [%{"posts" => ["titleShout"]}]}]))
    end
  end

  describe "Atomizer without a resource context" do
    alias AshRpc.FieldProcessing.Atomizer

    test "keeps string field names as sent and never mints atoms" do
      unknown = "notAField#{System.unique_integer([:positive])}"

      assert Atomizer.atomize_requested_fields(["id", "isActive", unknown], nil, runtime()) ==
               ["id", "isActive", unknown]

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end

    test "passes atom field names through unchanged" do
      assert Atomizer.atomize_requested_fields([:id, :title, :is_active?], nil, runtime()) ==
               [:id, :title, :is_active?]
    end

    test "keeps nested selections and calculation envelopes as sent" do
      fields = [
        "id",
        %{"author" => ["id", "isActive"]},
        %{"calc" => %{"args" => %{"count" => 5}, "fields" => ["value"]}}
      ]

      assert Atomizer.atomize_requested_fields(fields, nil, runtime()) == fields
    end
  end

  describe "strict field names" do
    test "an internal snake_case name under camelCase is unknown_field with the name as sent" do
      assert %{"success" => false, "errors" => [error]} = run("list_posts", ["id", "view_count"])

      assert %{"type" => "unknown_field", "fields" => ["view_count"]} = error
    end

    test "a nested relationship field in a non-client casing is unknown_field" do
      assert %{"success" => false, "errors" => [%{"type" => "unknown_field"}]} =
               run("list_posts", ["id", %{"author" => ["is_active?"]}])
    end

    test "duplicates are detected on resolved names" do
      assert {:error, {:duplicate_field, :is_active?, _}} =
               AshRpc.Pipeline.parse_request(runtime(), %AshRpc.Context{}, %{
                 "action" => "list_authors",
                 "fields" => ["isActive", :is_active?]
               })
    end
  end

  describe "field-selection error paths use decorated client names" do
    defmodule ContainerOverrideSource do
      @moduledoc false
      # Overrides on fields that hold nested data, so a selection path runs
      # through them.
      @behaviour AshRpc.MappingSource
      alias AshRpc.Test.MappingSource

      @impl true
      defdelegate output_formatter, to: MappingSource
      @impl true
      defdelegate exposed_resource?(resource), to: MappingSource

      @impl true
      def field_names(AshRpc.Test.Intake),
        do: Map.put(MappingSource.field_names(AshRpc.Test.Intake), :section, "intakeSection")

      def field_names(AshRpc.Test.IntakeSection),
        do:
          Map.put(
            MappingSource.field_names(AshRpc.Test.IntakeSection),
            :profile,
            "sectionProfile"
          )

      def field_names(resource), do: MappingSource.field_names(resource)

      @impl true
      defdelegate argument_names(resource, action), to: MappingSource
      @impl true
      defdelegate type_field_names(type), to: MappingSource
      @impl true
      defdelegate entrypoint(entrypoint), to: MappingSource
    end

    setup do
      %{manifest: AshRpc.Test.ManifestBuilder.build(mapping_source: ContainerOverrideSource)}
    end

    defp search_error(fields, opts \\ []) do
      params = %{"action" => "search_intakes", "input" => %{"query" => "x"}, "fields" => fields}
      single_error(AshRpc.run_action(@profile, %AshRpc.Context{}, params, opts))
    end

    test "path segments and the dotted field use overrides on the way", %{manifest: m} do
      error =
        search_error(["id", %{"intakeSection" => [%{"sectionProfile" => ["nope"]}]}], manifest: m)

      assert error["type"] == "unknown_field"
      assert error["path"] == ["intakeSection", "sectionProfile"]
      assert error["fields"] == ["intakeSection.sectionProfile.nope"]
      assert error["vars"]["field"] == "intakeSection.sectionProfile.nope"
    end

    test "an atom field is named against the node the path ends at", %{manifest: m} do
      error =
        search_error(
          ["id", %{"intakeSection" => [%{"sectionProfile" => [%{"isPublic" => ["x"]}]}]}],
          manifest: m
        )

      assert error["path"] == ["intakeSection", "sectionProfile"]
      assert error["fields"] == ["intakeSection.sectionProfile.isPublic"]
    end

    test "with the default manifest, a nested override is the field's client name" do
      error = search_error(["id", %{"profile" => [%{"isPublic" => ["x"]}]}])
      assert error["path"] == ["profile"]
      assert error["fields"] == ["profile.isPublic"]
    end

    test "a generic action names fields against its decorated return type" do
      error = single_error(run("catalog_stats_list", [%{"isFeatured" => ["x"]}]))
      assert error["type"] == "invalid_field_selection"
      assert error["path"] == ["isFeatured"]
    end
  end
end
