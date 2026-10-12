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
    defdelegate input_formatter, to: AshRpc.Test.MappingSource
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

  defp run(params, manifest),
    do: AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params, manifest: manifest)

  # Formatter variants are built once per module; tests pick theirs by name.
  setup_all do
    %{
      manifests: %{
        pascal_case:
          AshRpc.Test.ManifestBuilder.build(
            input_formatter: :pascal_case,
            output_formatter: :pascal_case
          ),
        snake_case:
          AshRpc.Test.ManifestBuilder.build(
            input_formatter: :snake_case,
            output_formatter: :snake_case
          )
      }
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
                   "palette",
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

    test "snake_case keys in nested input and nested selection are accepted and output is camelCase" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_project",
                 "input" => %{
                   "metadata" => %{"category" => "development", "priority_score" => 9},
                   "stats" => %{
                     "view_count" => 15,
                     "edit_count" => 3,
                     "metrics" => %{"focus_seconds" => 1200, "efficiency" => 0.85}
                   }
                 },
                 "fields" => [
                   %{"metadata" => ["category", "priority_score"]},
                   %{
                     "stats" => [
                       "view_count",
                       "edit_count",
                       %{"metrics" => ["focus_seconds", "efficiency"]}
                     ]
                   }
                 ]
               })

      assert data == %{
               "metadata" => %{"category" => "development", "priorityScore" => 9},
               "stats" => %{
                 "viewCount" => 15,
                 "editCount" => 3,
                 "metrics" => %{"focusSeconds" => 1200, "efficiency" => 0.85}
               }
             }
    end
  end

  # Client names from the mapping source are used exactly as given under every
  # formatter; only names without an override pass through the formatter.
  describe "overrides under non-camelCase formatters" do
    for {formatter, names} <- [
          pascal_case: %{
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
              "action" => "create_intake",
              "input" => %{
                n.user_name => "someone",
                n.stats => %{
                  "totalCount1" => 5,
                  "isComplete" => true,
                  n.last_updated_at => "2024-01-01T00:00:00Z"
                }
              },
              "fields" => [%{n.stats => ["totalCount1", "isComplete", n.last_updated_at]}]
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
              "action" => "catalog_task_stats",
              "input" => %{n.task_id => Ash.UUID.generate()},
              "fields" => [n.total_count, "completed", "isUrgent"]
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
            %{"action" => "list_authors", "fields" => [n.id, n.name, "isActive"]},
            manifests[@formatter]
          )

        assert result == %{
                 n.success => true,
                 n.data => [%{n.id => author.id, n.name => "Ada", "isActive" => true}]
               }
      end
    end
  end
end
