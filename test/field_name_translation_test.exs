# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldNameTranslationTest do
  use ExUnit.Case, async: true

  # Post's client names collide with names elsewhere: "name" with Author's own
  # `name` attribute, "total" with a field of the `totals` action's typed return.
  # Each selection must be translated with the names of the type it belongs to.
  defmodule CollidingMappingSource do
    @moduledoc false
    @behaviour AshRpc.MappingSource

    @impl true
    defdelegate output_formatter, to: AshRpc.Test.MappingSource
    @impl true
    defdelegate exposed_resource?(resource), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate argument_names(resource, action), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate type_field_names(type), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate entrypoint(entrypoint), to: AshRpc.Test.MappingSource

    @impl true
    def field_names(AshRpc.Test.Post), do: %{view_count: "name", title: "total"}
    def field_names(resource), do: AshRpc.Test.MappingSource.field_names(resource)
  end

  defp manifest do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: :ash_rpc,
        action_entrypoints: [
          %{
            resource: AshRpc.Test.Post,
            action: :read,
            config: %{ash_rpc_test: %{name: "list_posts"}}
          },
          %{
            resource: AshRpc.Test.Post,
            action: :totals,
            config: %{ash_rpc_test: %{name: "totals"}}
          }
        ]
      )

    AshRpc.Manifest.Decorator.decorate(manifest, CollidingMappingSource, [])
  end

  test "nested relationship fields are translated with the related resource's names" do
    assert %{"success" => true, "data" => []} =
             AshRpc.run_action(
               AshRpc.Test.Profile,
               %AshRpc.Context{},
               %{"action" => "list_posts", "fields" => ["id", %{"author" => ["name"]}]},
               manifest: manifest()
             )
  end

  test "a generic action's typed return is not translated with the resource's names" do
    assert %{"success" => true, "data" => %{"total" => 2}} =
             AshRpc.run_action(
               AshRpc.Test.Profile,
               %AshRpc.Context{},
               %{"action" => "totals", "fields" => ["total"]},
               manifest: manifest()
             )
  end

  defp run(params), do: AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params)

  defp parse(params),
    do:
      AshRpc.Pipeline.parse_request(
        AshRpc.Runtime.new(AshRpc.Test.Profile),
        %AshRpc.Context{},
        params
      )

  defp set_viewed(post, input) do
    run(%{
      "action" => "set_post_viewed",
      "identity" => post.id,
      "input" => input,
      "fields" => ["id", "title", "viewCount"]
    })
  end

  defp run(params, manifest),
    do: AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params, manifest: manifest)

  # Formatter variants are built once per module; tests pick theirs by name.
  @round_trip_formatters [
    :camel_case,
    :pascal_case,
    :snake_case,
    {AshRpc.Test.Formatters, :upcase}
  ]

  setup_all do
    %{
      manifests: %{
        pascal_case: AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case),
        snake_case: AshRpc.Test.ManifestBuilder.build(output_formatter: :snake_case)
      },
      round_trip:
        for f <- @round_trip_formatters, into: %{} do
          {f, AshRpc.Test.ManifestBuilder.build(output_formatter: f)}
        end
    }
  end

  describe "output value types" do
    test "dates, datetimes and atoms become strings; calculation booleans and integers keep their type" do
      due = ~D[2099-12-31]
      today = Date.utc_today()

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_project",
                 "input" => %{
                   "dueDate" => Date.to_iso8601(due),
                   "startedAt" => "2024-01-01T12:00:00Z",
                   "priority" => "high",
                   "metadata" => %{"category" => "testing", "deadline" => "2099-06-30"},
                   "palette" => %{"primary" => "#3498DB", "secondary" => "#E74C3C"}
                 },
                 "fields" => [
                   "dueDate",
                   "startedAt",
                   "priority",
                   "isLate",
                   "daysLeft",
                   %{"palette" => ["primary", "secondary"]},
                   %{"metadata" => ["category", "deadline"]}
                 ]
               })

      after_today = Date.utc_today()

      # The request may straddle midnight, so either day's count is accepted.
      assert data["daysLeft"] in [Date.diff(due, today), Date.diff(due, after_today)]

      assert Map.delete(data, "daysLeft") == %{
               "dueDate" => "2099-12-31",
               "startedAt" => "2024-01-01T12:00:00Z",
               "priority" => "high",
               "isLate" => false,
               "palette" => %{"primary" => "#3498DB", "secondary" => "#E74C3C"},
               "metadata" => %{"category" => "testing", "deadline" => "2099-06-30"}
             }
    end

    test "snake_case keys in a nested selection are not client names" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "create_project",
                 "input" => %{"metadata" => %{"category" => "development", "priorityScore" => 9}},
                 "fields" => [%{"metadata" => ["category", "priority_score"]}]
               })

      assert %{"type" => "unknown_field", "fields" => ["metadata.priority_score"]} = error
    end
  end

  # Client names from the mapping source are used exactly as given under every
  # formatter; only names without an override pass through the formatter.
  describe "overrides under non-camelCase formatters" do
    for {formatter, names} <- [
          pascal_case: %{
            action: "Action",
            fields: "Fields",
            success: "Success",
            data: "Data",
            id: "Id",
            name: "Name",
            user_name: "UserName",
            stats: "Stats",
            task_id: "TaskId",
            last_updated_at: "LastUpdatedAt",
            total_count: "TotalCount"
          },
          snake_case: %{
            action: "action",
            fields: "fields",
            success: "success",
            data: "data",
            id: "id",
            name: "name",
            user_name: "user_name",
            stats: "stats",
            task_id: "task_id",
            last_updated_at: "last_updated_at",
            total_count: "total_count"
          }
        ] do
      @formatter formatter
      @names names

      test "#{formatter}: type-level overrides are used as-is in nested typed-map input and output",
           %{manifests: manifests} do
        n = @names

        result =
          run(
            %{
              n.action => "create_intake",
              "input" => %{
                n.user_name => "someone",
                n.stats => %{
                  "totalCount1" => 5,
                  "isComplete" => true,
                  n.last_updated_at => "2024-01-01T00:00:00Z"
                }
              },
              n.fields => [%{n.stats => ["totalCount1", "isComplete", n.last_updated_at]}]
            },
            manifests[@formatter]
          )

        assert result == %{
                 n.success => true,
                 n.data => %{
                   n.stats => %{
                     "totalCount1" => 5,
                     "isComplete" => true,
                     n.last_updated_at => "2024-01-01T00:00:00Z"
                   }
                 }
               }
      end

      test "#{formatter}: a generic action's typed return keeps overrides and formats the rest",
           %{manifests: manifests} do
        n = @names

        result =
          run(
            %{
              n.action => "catalog_task_stats",
              "input" => %{n.task_id => Ash.UUID.generate()},
              n.fields => [n.total_count, "completed", "isUrgent"]
            },
            manifests[@formatter]
          )

        assert result == %{
                 n.success => true,
                 n.data => %{n.total_count => 10, "completed" => true, "isUrgent" => false}
               }
      end

      test "#{formatter}: a resource field override wins over the formatter",
           %{manifests: manifests} do
        n = @names
        author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})

        result =
          run(
            %{n.action => "list_authors", n.fields => [n.id, n.name, "isActive"]},
            manifests[@formatter]
          )

        assert result == %{
                 n.success => true,
                 n.data => [%{n.id => author.id, n.name => "Ada", "isActive" => true}]
               }
      end
    end
  end

  describe "mapped attribute names on input" do
    test "a create accepts the mapped attribute name and stores it under the internal name" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_author",
                 "input" => %{"name" => "Ada", "isActive" => false},
                 "fields" => ["id", "name", "isActive"]
               })

      assert [%AshRpc.Test.Author{name: "Ada", is_active?: false} = author] =
               Ash.read!(AshRpc.Test.Author)

      assert data == %{"id" => author.id, "name" => "Ada", "isActive" => false}
    end

    test "an update accepts the mapped attribute name and returns it under the mapped name" do
      author = Ash.create!(AshRpc.Test.Author, %{name: "Ada", is_active?: true})

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "update_author",
                 "identity" => author.id,
                 "input" => %{"name" => "Grace", "isActive" => false},
                 "fields" => ["id", "name", "isActive"]
               })

      assert data == %{"id" => author.id, "name" => "Grace", "isActive" => false}

      assert %AshRpc.Test.Author{name: "Grace", is_active?: false} =
               Ash.get!(AshRpc.Test.Author, author.id)
    end
  end

  # `set_post_viewed` maps the `is_viewed?` argument to "isViewed"; its inline
  # change reads `:is_viewed?` and sets `view_count` to 1 (true) or 0 (false).
  describe "mapped argument names on input" do
    setup do
      %{post: Ash.create!(AshRpc.Test.Post, %{title: "Hello", view_count: 5})}
    end

    test "an inline change reads the mapped argument under its internal name", %{post: post} do
      assert {:ok, %AshRpc.Request{input: input}} =
               parse(%{
                 "action" => "set_post_viewed",
                 "identity" => post.id,
                 "input" => %{"isViewed" => true},
                 "fields" => ["id"]
               })

      assert input == %{is_viewed?: true}

      assert set_viewed(post, %{"isViewed" => true}) == %{
               "success" => true,
               "data" => %{"id" => post.id, "title" => "Hello", "viewCount" => 1}
             }

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 1
    end

    test "a false mapped argument reaches the action as false", %{post: post} do
      assert set_viewed(post, %{"isViewed" => false}) == %{
               "success" => true,
               "data" => %{"id" => post.id, "title" => "Hello", "viewCount" => 0}
             }

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 0
    end

    test "validate_action accepts the mapped argument without running the action",
         %{post: post} do
      for value <- [true, false] do
        assert AshRpc.validate_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
                 "action" => "set_post_viewed",
                 "identity" => post.id,
                 "input" => %{"isViewed" => value}
               }) == %{"success" => true}
      end

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 5
    end

    test "a missing required mapped argument is reported under its client name",
         %{post: post} do
      assert %{"success" => false, "errors" => [run_error]} = set_viewed(post, %{})

      assert Map.take(run_error, ["type", "shortMessage", "fields", "vars"]) == %{
               "type" => "required",
               "shortMessage" => "Required field",
               "fields" => ["isViewed"],
               "vars" => %{"field" => "isViewed"}
             }

      assert %{"success" => false, "errors" => [error]} =
               AshRpc.validate_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
                 "action" => "set_post_viewed",
                 "identity" => post.id,
                 "input" => %{}
               })

      assert error == %{
               "type" => "required",
               "message" => "argument %{field} is required",
               "shortMessage" => "Required field",
               "fields" => ["isViewed"],
               "path" => [],
               "vars" => %{"field" => "isViewed"}
             }

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 5
    end

    test "an update error on run_action has the same message and path as on validate_action",
         %{post: post} do
      assert set_viewed(post, %{}) == %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "required",
                   "message" => "argument %{field} is required",
                   "shortMessage" => "Required field",
                   "fields" => ["isViewed"],
                   "path" => [],
                   "vars" => %{"field" => "isViewed"}
                 }
               ]
             }
    end
  end

  # `set_viewed` also has a private `audit_note` argument (`public? false`).
  # It has no client name, so it must never reach the action from the wire.
  describe "private action arguments on input" do
    setup do
      %{post: Ash.create!(AshRpc.Test.Post, %{title: "Hello", view_count: 5})}
    end

    test "a rejected private argument is unknown_input under its client name", %{post: post} do
      assert set_viewed(post, %{"isViewed" => true, "auditNote" => "x"}) == %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unknown_input",
                   "message" => "Unknown input %{field}",
                   "shortMessage" => "Unknown input",
                   "fields" => ["auditNote"],
                   "path" => [],
                   "vars" => %{"field" => "auditNote"},
                   "details" => %{"hint" => AshRpc.Test.Profile.stale_client_hint()}
                 }
               ]
             }

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 5
    end

    test "a private argument under its internal name is unknown_input", %{post: post} do
      params = %{
        "action" => "set_post_viewed",
        "identity" => post.id,
        "input" => %{"isViewed" => true, "audit_note" => "x"},
        "fields" => ["id"]
      }

      # Private arguments have no client name, so the key is rejected before
      # Ash runs instead of being passed through and ignored.
      assert parse(params) == {:error, [unknown_input: "audit_note"]}

      assert %{
               "success" => false,
               "errors" => [%{"type" => "unknown_input", "fields" => ["audit_note"]}]
             } =
               set_viewed(post, %{"isViewed" => true, "audit_note" => "x"})

      assert Ash.get!(AshRpc.Test.Post, post.id).view_count == 5
    end
  end

  describe "wire round trip" do
    for f <- @round_trip_formatters do
      @f f
      test "every request part uses client names under #{inspect(f)}", %{round_trip: manifests} do
        f = @f
        m = Map.fetch!(manifests, f)
        n = &AshRpc.FieldFormatter.format_field_name(&1, f)
        run = &AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, &1, manifest: m)

        post =
          Ash.create!(AshRpc.Test.Post, %{title: "Hello world", view_count: 3, slug: "hello"})

        Ash.create!(AshRpc.Test.Comment, %{body: "a", rating: 1, post_id: post.id})
        Ash.create!(AshRpc.Test.Comment, %{body: "b", rating: 5, post_id: post.id})

        # create: input keys
        created =
          run.(%{
            n.(:action) => "create_post",
            "input" => %{n.(:title) => "Other", n.(:view_count) => 0},
            n.(:fields) => [n.(:id)]
          })

        assert created[n.(:success)] == true

        # list: fields with calc args and a nested envelope, sort, filter
        list =
          run.(%{
            n.(:action) => "list_posts",
            n.(:fields) => [
              n.(:title),
              %{n.(:excerpt) => %{n.(:args) => %{n.(:length) => 2, n.(:omission_text) => "~"}}},
              %{
                n.(:comments) => %{
                  n.(:fields) => [n.(:rating)],
                  n.(:sort) => "-" <> n.(:rating),
                  n.(:filter) => %{n.(:rating) => %{n.(:greater_than) => 1}}
                }
              }
            ],
            n.(:sort) => "-" <> n.(:view_count),
            n.(:filter) => %{n.(:view_count) => %{n.(:greater_than_or_equal) => 1}}
          })

        assert list[n.(:success)] == true

        assert [row] = list[n.(:data)]
        assert row[n.(:title)] == "Hello world"
        assert row[n.(:excerpt)] == "He~"
        assert row[n.(:comments)] == [%{n.(:rating) => 5}]

        # page
        paged =
          run.(%{
            n.(:action) => "list_posts",
            n.(:fields) => [n.(:id)],
            n.(:page) => %{n.(:limit) => 1}
          })

        assert [_] = paged[n.(:data)][n.(:results)]

        # getBy
        got =
          run.(%{
            n.(:action) => "get_post_by_slug",
            n.(:fields) => [n.(:title)],
            n.(:get_by) => %{n.(:slug) => "hello"}
          })

        assert got[n.(:data)] == %{n.(:title) => "Hello world"}

        # metadataFields (meta_1 is overridden to "meta1" in every manifest)
        meta =
          run.(%{
            n.(:action) => "read_posts_with_metadata",
            n.(:fields) => [n.(:id)],
            n.(:metadata_fields) => [n.(:total_score), "meta1"]
          })

        assert [%{} = record | _] = meta[n.(:data)]
        assert record[n.(:total_score)] == 42
        assert record["meta1"] == "m1"
      end
    end
  end
end
