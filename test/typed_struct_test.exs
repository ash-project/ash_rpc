# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.TypedStructTest do
  use ExUnit.Case, async: true

  alias AshRpc.{RequestedFieldsProcessor, Runtime}

  @stats %{
    "viewCount" => 3,
    "editCount" => 1,
    "allDone" => true,
    "metrics" => %{"focusSeconds" => 120, "efficiency" => 0.5}
  }

  @hint AshRpc.Test.Profile.stale_client_hint()

  defp run(params), do: AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params)

  defp create_project!(stats \\ @stats) do
    assert %{"success" => true, "data" => %{"id" => id}} =
             run(%{
               "action" => "create_project",
               "input" => %{"stats" => stats},
               "fields" => ["id"]
             })

    id
  end

  defp get_project(fields), do: run(%{"action" => "get_project", "fields" => fields})

  # An empty top-level fields list is rejected before the return type is
  # looked at, so this is empty_fields_array, not requires_field_selection.
  @empty_fields_error %{
    "type" => "empty_fields_array",
    "message" => "Fields array cannot be empty",
    "shortMessage" => "Empty fields array",
    "fields" => [],
    "path" => [],
    "vars" => %{},
    "details" => %{"suggestion" => "Provide at least one field name in the fields array"}
  }

  defp single_error(%{"success" => false, "errors" => [error]}), do: error

  describe "typed struct attribute selection" do
    setup do
      %{id: create_project!()}
    end

    test "returns the selected fields, with override names", %{id: id} do
      assert get_project(["id", %{"stats" => ["viewCount", "editCount", "allDone"]}]) == %{
               "success" => true,
               "data" => %{
                 "id" => id,
                 "stats" => %{"viewCount" => 3, "editCount" => 1, "allDone" => true}
               }
             }
    end

    test "returns only a partial selection" do
      assert get_project([%{"stats" => ["editCount"]}]) == %{
               "success" => true,
               "data" => %{"stats" => %{"editCount" => 1}}
             }
    end

    test "returns every field, including the nested map", %{id: id} do
      assert %{"success" => true, "data" => data} =
               get_project([
                 "id",
                 %{
                   "stats" => [
                     "viewCount",
                     "editCount",
                     "allDone",
                     %{"metrics" => ["focusSeconds", "efficiency"]}
                   ]
                 }
               ])

      assert data == %{"id" => id, "stats" => @stats}
    end

    test "selects part of the nested map" do
      assert %{"success" => true, "data" => data} =
               get_project([%{"stats" => ["viewCount", %{"metrics" => ["efficiency"]}]}])

      assert data == %{"stats" => %{"viewCount" => 3, "metrics" => %{"efficiency" => 0.5}}}
    end
  end

  describe "typed struct selection errors" do
    test "an unknown field is unknown_field with the struct path" do
      assert single_error(get_project([%{"stats" => ["viewCount", "invalidField"]}])) == %{
               "type" => "unknown_field",
               "message" => "Unknown field %{field} for %{kind} type",
               "shortMessage" => "Unknown field",
               "fields" => ["stats.invalidField"],
               "path" => ["stats"],
               "vars" => %{"field" => "stats.invalidField", "kind" => "field constrained"},
               "details" => %{
                 "hint" => @hint,
                 "suggestion" =>
                   "Check that the field name is valid for the type's field constraints"
               }
             }
    end

    test "a duplicate field is duplicate_field" do
      assert %{"type" => "duplicate_field", "path" => ["stats"]} =
               error = single_error(get_project([%{"stats" => ["viewCount", "viewCount"]}]))

      assert error["fields"] == ["stats.viewCount"]
      assert error["vars"] == %{"field" => "stats.viewCount"}
      assert error["details"] == %{"suggestion" => "Remove duplicate field specifications"}
    end

    test "a bare field name requires field selection" do
      assert %{"type" => "requires_field_selection", "fields" => ["stats"], "path" => []} =
               error = single_error(get_project(["stats"]))

      assert error["vars"] == %{"field" => "stats", "fieldType" => "Field_constrained_type"}
      assert error["details"]["hint"] == @hint
    end

    test "an empty field list requires field selection" do
      assert %{"type" => "requires_field_selection", "fields" => ["stats"], "path" => []} =
               error = single_error(get_project([%{"stats" => []}]))

      assert error["vars"] == %{"field" => "stats", "fieldType" => "Field_constrained_type"}
    end

    test "an unknown nested map field is unknown_map_field with the full path" do
      assert %{"type" => "unknown_map_field", "path" => ["stats", "metrics"]} =
               error =
               single_error(get_project([%{"stats" => [%{"metrics" => ["invalidField"]}]}]))

      assert error["fields"] == ["stats.metrics.invalidField"]
      assert error["vars"] == %{"field" => "stats.metrics.invalidField"}
      assert error["details"]["hint"] == @hint
    end

    test "a duplicate nested map field is duplicate_field with the full path" do
      assert %{"type" => "duplicate_field", "path" => ["stats", "metrics"]} =
               error =
               single_error(
                 get_project([%{"stats" => [%{"metrics" => ["efficiency", "efficiency"]}]}])
               )

      assert error["fields"] == ["stats.metrics.efficiency"]
      assert error["vars"] == %{"field" => "stats.metrics.efficiency"}
      assert error["details"] == %{"suggestion" => "Remove duplicate field specifications"}
    end
  end

  describe "processor templates" do
    setup do
      %{rt: Runtime.new(AshRpc.Test.Profile)}
    end

    test "a typed struct is selected, not loaded, and keys the template by internal name",
         %{rt: rt} do
      assert {:ok, {[:id, :stats], [], [:id, stats: [:view_count, :all_done?]]}} =
               RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, [
                 "id",
                 %{"stats" => ["viewCount", "allDone"]}
               ])
    end

    test "a nested map inside the struct nests in the template", %{rt: rt} do
      assert {:ok, {[:stats], [], template}} =
               RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, [
                 %{"stats" => ["viewCount", %{"metrics" => ["focusSeconds", "efficiency"]}]}
               ])

      assert template == [stats: [:view_count, metrics: [:focus_seconds, :efficiency]]]
    end

    test "an unknown nested map field reports kind map and the struct path", %{rt: rt} do
      assert RequestedFieldsProcessor.process(rt, AshRpc.Test.Project, :read, [
               %{"stats" => [%{"metrics" => ["invalidField"]}]}
             ]) == {:error, {:unknown_field, "invalidField", "map", [:stats, :metrics]}}
    end
  end

  describe "typed struct input" do
    test "create stores the struct" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_project",
                 "input" => %{"stats" => @stats},
                 "fields" => [
                   %{
                     "stats" => [
                       "viewCount",
                       "editCount",
                       "allDone",
                       %{"metrics" => ["focusSeconds", "efficiency"]}
                     ]
                   }
                 ]
               })

      assert data == %{"stats" => @stats}
    end

    test "update replaces the struct and the change reads back" do
      id = create_project!()

      assert %{"success" => true, "data" => %{"stats" => %{"viewCount" => 9, "allDone" => false}}} =
               run(%{
                 "action" => "update_project",
                 "identity" => id,
                 "input" => %{
                   "stats" => %{
                     "viewCount" => 9,
                     "allDone" => false,
                     "metrics" => %{"focusSeconds" => 5}
                   }
                 },
                 "fields" => [%{"stats" => ["viewCount", "allDone"]}]
               })

      assert get_project([
               %{
                 "stats" => [
                   "viewCount",
                   "editCount",
                   "allDone",
                   %{"metrics" => ["focusSeconds"]}
                 ]
               }
             ]) == %{
               "success" => true,
               "data" => %{
                 "stats" => %{
                   "viewCount" => 9,
                   "editCount" => 0,
                   "allDone" => false,
                   "metrics" => %{"focusSeconds" => 5}
                 }
               }
             }
    end
  end

  describe "generic action returning a typed struct" do
    defp task_stats(fields) do
      run(%{
        "action" => "catalog_task_stats",
        "input" => %{"taskId" => Ash.UUID.generate()},
        "fields" => fields
      })
    end

    test "returns a partial selection under the override names" do
      assert task_stats(["totalCount", "completed", "isUrgent"]) == %{
               "success" => true,
               "data" => %{"totalCount" => 10, "completed" => true, "isUrgent" => false}
             }
    end

    test "returns every field" do
      assert task_stats(["totalCount", "completed", "isUrgent", "averageDuration"]) == %{
               "success" => true,
               "data" => %{
                 "totalCount" => 10,
                 "completed" => true,
                 "isUrgent" => false,
                 "averageDuration" => 2.5
               }
             }
    end

    test "an unknown field is unknown_field" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["invalidField"],
               "path" => [],
               "vars" => %{"field" => "invalidField", "kind" => "field constrained"},
               "details" => %{"hint" => @hint}
             } = single_error(task_stats(["invalidField"]))
    end

    test "an empty field list is empty_fields_array" do
      assert single_error(task_stats([])) == @empty_fields_error
    end
  end

  describe "generic action returning an array of typed structs" do
    defp task_stats_list(fields),
      do: run(%{"action" => "catalog_task_stats_list", "fields" => fields})

    test "returns a partial selection for every item" do
      assert task_stats_list(["totalCount", "completed", "isUrgent"]) == %{
               "success" => true,
               "data" => [
                 %{"totalCount" => 1, "completed" => true, "isUrgent" => true},
                 %{"totalCount" => 2, "completed" => false, "isUrgent" => false}
               ]
             }
    end

    test "returns every field for every item" do
      assert task_stats_list(["totalCount", "completed", "isUrgent", "averageDuration"]) == %{
               "success" => true,
               "data" => [
                 %{
                   "totalCount" => 1,
                   "completed" => true,
                   "isUrgent" => true,
                   "averageDuration" => 1.0
                 },
                 %{
                   "totalCount" => 2,
                   "completed" => false,
                   "isUrgent" => false,
                   "averageDuration" => nil
                 }
               ]
             }
    end

    test "an unknown field is unknown_field" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["invalidField"],
               "path" => [],
               "vars" => %{"field" => "invalidField", "kind" => "field constrained"},
               "details" => %{"hint" => @hint}
             } = single_error(task_stats_list(["invalidField"]))
    end

    test "an empty field list is empty_fields_array" do
      assert single_error(task_stats_list([])) == @empty_fields_error
    end
  end
end
