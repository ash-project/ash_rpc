# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.EmbeddedResourcesTest do
  use ExUnit.Case, async: true

  alias AshRpc.RequestedFieldsProcessor

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp get_project(fields), do: run(%{"action" => "get_project", "fields" => fields})

  defp process(fields) do
    RequestedFieldsProcessor.process(
      AshRpc.Runtime.new(@profile),
      AshRpc.Test.Project,
      :read,
      fields
    )
  end

  defp single_error(%{"success" => false, "errors" => [error]}), do: error

  # One project whose `metadata` carries every ProjectMeta attribute, including
  # the private `internal_notes`, and whose `history` holds two entries.
  defp seed_project! do
    Ash.create!(AshRpc.Test.Project, %{
      metadata: %{
        category: "work",
        priority_score: 85,
        is_urgent: true,
        deadline: ~D[2026-01-15],
        status: :active,
        detail: %{note: "first", level: 2},
        internal_notes: "never on the wire"
      },
      history: [
        %{category: "personal", priority_score: 60},
        %{category: "work", priority_score: 90}
      ]
    })
  end

  describe "selecting an embedded attribute" do
    setup do
      %{project: seed_project!()}
    end

    test "attributes are selected with the embedded value; nothing is loaded", %{
      project: project
    } do
      fields = [:id, %{metadata: [:category, :priority_score, :is_urgent]}]

      assert {:ok, {[:id, :metadata], [], template}} = process(fields)
      assert template == [:id, metadata: [:category, :priority_score, :is_urgent]]

      assert %{"success" => true, "data" => data} =
               get_project(["id", %{"metadata" => ["category", "priorityScore", "isUrgent"]}])

      assert data == %{
               "id" => project.id,
               "metadata" => %{"category" => "work", "priorityScore" => 85, "isUrgent" => true}
             }
    end

    test "a calculation without arguments is loaded through the embedded value", %{
      project: project
    } do
      fields = [:id, %{metadata: [:category, :priority_score, :display_category]}]

      assert {:ok, {[:id, :metadata], [metadata: [:display_category]], template}} =
               process(fields)

      assert template == [:id, metadata: [:category, :priority_score, :display_category]]

      assert %{"success" => true, "data" => data} =
               get_project([
                 "id",
                 %{"metadata" => ["category", "priorityScore", "displayCategory"]}
               ])

      assert data == %{
               "id" => project.id,
               "metadata" => %{
                 "category" => "work",
                 "priorityScore" => 85,
                 "displayCategory" => "category:work"
               }
             }
    end

    test "a calculation with arguments takes args and is loaded with them" do
      fields = [:id, %{metadata: [:category, %{adjusted_priority: %{args: %{multiplier: 2}}}]}]

      assert {:ok, {[:id, :metadata], load, template}} = process(fields)
      assert load == [metadata: [adjusted_priority: %{multiplier: 2}]]
      assert template == [:id, metadata: [:category, :adjusted_priority]]

      assert %{"success" => true, "data" => data} =
               get_project([
                 %{
                   "metadata" => [
                     "category",
                     %{"adjustedPriority" => %{"args" => %{"multiplier" => 2}}}
                   ]
                 }
               ])

      # priority_score 85 * 2
      assert data == %{"metadata" => %{"category" => "work", "adjustedPriority" => 170}}
    end

    test "a nested embedded attribute takes its own field selection" do
      fields = [%{metadata: [:category, %{detail: [:note, :level]}]}]

      assert {:ok, {[:metadata], [], template}} = process(fields)
      assert template == [metadata: [:category, detail: [:note, :level]]]

      assert %{"success" => true, "data" => data} =
               get_project([%{"metadata" => ["category", %{"detail" => ["note", "level"]}]}])

      assert data == %{
               "metadata" => %{
                 "category" => "work",
                 "detail" => %{"note" => "first", "level" => 2}
               }
             }
    end

    test "date and atom attributes inside the embedded value are formatted" do
      assert %{"success" => true, "data" => data} =
               get_project([%{"metadata" => ["deadline", "status"]}])

      assert data == %{"metadata" => %{"deadline" => "2026-01-15", "status" => "active"}}
    end
  end

  describe "selecting an array of embedded resources" do
    setup do
      %{project: seed_project!()}
    end

    test "each entry gets the selection; unselected attributes are absent", %{project: project} do
      fields = [:id, %{history: [:category]}]

      assert {:ok, {[:id, :history], [], [:id, history: [:category]]}} = process(fields)

      assert %{"success" => true, "data" => data} =
               get_project(["id", %{"history" => ["category"]}])

      assert data == %{
               "id" => project.id,
               "history" => [%{"category" => "personal"}, %{"category" => "work"}]
             }
    end

    test "calculations are loaded through the array" do
      fields = [
        %{
          history: [
            :category,
            :display_category,
            %{adjusted_priority: %{args: %{multiplier: 3}}}
          ]
        }
      ]

      assert {:ok, {[:history], load, template}} = process(fields)
      assert load == [history: [:display_category, adjusted_priority: %{multiplier: 3}]]
      assert template == [history: [:category, :display_category, :adjusted_priority]]

      assert %{"success" => true, "data" => data} =
               get_project([
                 %{
                   "history" => [
                     "category",
                     "displayCategory",
                     %{"adjustedPriority" => %{"args" => %{"multiplier" => 3}}}
                   ]
                 }
               ])

      assert data == %{
               "history" => [
                 %{
                   "category" => "personal",
                   "displayCategory" => "category:personal",
                   "adjustedPriority" => 180
                 },
                 %{
                   "category" => "work",
                   "displayCategory" => "category:work",
                   "adjustedPriority" => 270
                 }
               ]
             }
    end
  end

  describe "a private embedded attribute" do
    setup do
      %{project: seed_project!()}
    end

    test "selecting it is unknown_field", %{project: project} do
      # The stored value exists, so the error is not just a missing field.
      assert project.metadata.internal_notes == "never on the wire"

      assert {:error, {:unknown_field, :internal_notes, AshRpc.Test.ProjectMeta, [:metadata]}} =
               process([%{metadata: [:internal_notes]}])

      assert %{
               "type" => "unknown_field",
               "fields" => ["metadata.internalNotes"],
               "path" => ["metadata"],
               "vars" => %{
                 "field" => "metadata.internalNotes",
                 "resource" => "AshRpc.Test.ProjectMeta"
               }
             } = single_error(get_project([%{"metadata" => ["internalNotes"]}]))
    end

    test "its stored value never comes back with the other attributes" do
      public = [
        "category",
        "priorityScore",
        "isUrgent",
        "deadline",
        "status",
        "infoType",
        "displayCategory",
        %{"detail" => ["note", "level"]}
      ]

      assert %{"success" => true, "data" => data} =
               get_project([%{"metadata" => public}, %{"history" => public}])

      # internalNotes is absent from both values.
      assert data == %{
               "metadata" => %{
                 "category" => "work",
                 "priorityScore" => 85,
                 "isUrgent" => true,
                 "deadline" => "2026-01-15",
                 "status" => "active",
                 "infoType" => nil,
                 "displayCategory" => "category:work",
                 "detail" => %{"note" => "first", "level" => 2}
               },
               "history" => [
                 %{
                   "category" => "personal",
                   "priorityScore" => 60,
                   "isUrgent" => nil,
                   "deadline" => nil,
                   "status" => nil,
                   "infoType" => nil,
                   "displayCategory" => "category:personal",
                   "detail" => nil
                 },
                 %{
                   "category" => "work",
                   "priorityScore" => 90,
                   "isUrgent" => nil,
                   "deadline" => nil,
                   "status" => nil,
                   "infoType" => nil,
                   "displayCategory" => "category:work",
                   "detail" => nil
                 }
               ]
             }
    end
  end

  describe "field selection errors inside an embedded value" do
    test "an unknown field in the embedded attribute" do
      assert {:error, {:unknown_field, :invalid_field, AshRpc.Test.ProjectMeta, [:metadata]}} =
               process([%{metadata: [:invalid_field]}])

      assert %{
               "type" => "unknown_field",
               "fields" => ["metadata.invalidField"],
               "path" => ["metadata"],
               "vars" => %{
                 "field" => "metadata.invalidField",
                 "resource" => "AshRpc.Test.ProjectMeta"
               }
             } = single_error(get_project([%{"metadata" => ["invalidField"]}]))
    end

    test "an unknown field after a valid one in the embedded array" do
      assert {:error, {:unknown_field, :invalid_field, AshRpc.Test.ProjectMeta, [:history]}} =
               process([%{history: [:category, :invalid_field]}])

      assert %{
               "type" => "unknown_field",
               "fields" => ["history.invalidField"],
               "path" => ["history"]
             } = single_error(get_project([%{"history" => ["category", "invalidField"]}]))
    end

    test "an unknown field in a nested embedded attribute reports the full path" do
      assert {:error,
              {:unknown_field, :nope, AshRpc.Test.ProjectMetaDetail, [:metadata, :detail]}} =
               process([%{metadata: [%{detail: [:note, :nope]}]}])

      assert %{
               "type" => "unknown_field",
               "fields" => ["metadata.detail.nope"],
               "path" => ["metadata", "detail"],
               "vars" => %{
                 "field" => "metadata.detail.nope",
                 "resource" => "AshRpc.Test.ProjectMetaDetail"
               }
             } = single_error(get_project([%{"metadata" => [%{"detail" => ["note", "nope"]}]}]))
    end

    test "a calculation with arguments requested by bare name is calculation_requires_args" do
      assert {:error, {:calculation_requires_args, :adjusted_priority, [:metadata]}} =
               process([%{metadata: [:adjusted_priority]}])

      # The wire type for this reason is invalid_field_format.
      assert %{
               "type" => "invalid_field_format",
               "fields" => ["metadata.adjustedPriority"],
               "path" => ["metadata"],
               "vars" => %{"field" => "metadata.adjustedPriority"}
             } = single_error(get_project([%{"metadata" => ["adjustedPriority"]}]))
    end

    test "args on a calculation that takes none is invalid_calculation_args" do
      assert {:error, {:invalid_calculation_args, :display_category, [:metadata]}} =
               process([%{metadata: [%{display_category: %{args: %{}}}]}])

      assert %{
               "type" => "invalid_calculation_args",
               "fields" => ["metadata.displayCategory"],
               "path" => ["metadata"],
               "vars" => %{"field" => "metadata.displayCategory"}
             } =
               single_error(
                 get_project([%{"metadata" => [%{"displayCategory" => %{"args" => %{}}}]}])
               )
    end

    test "the same field twice in the embedded selection is duplicate_field, without a hint" do
      assert {:error, {:duplicate_field, :category, [:metadata]}} =
               process([%{metadata: [:category, :priority_score, :category]}])

      error =
        single_error(get_project([%{"metadata" => ["category", "priorityScore", "category"]}]))

      assert %{
               "type" => "duplicate_field",
               "fields" => ["metadata.category"],
               "path" => ["metadata"],
               "vars" => %{"field" => "metadata.category"}
             } = error

      refute Map.has_key?(error["details"], "hint")
    end

    test "the embedded attribute requested by bare name is requires_field_selection" do
      assert {:error, {:requires_field_selection, :embedded_resource, :metadata, []}} =
               process([:metadata])

      assert %{
               "type" => "requires_field_selection",
               "fields" => ["metadata"],
               "path" => [],
               "vars" => %{"field" => "metadata", "fieldType" => "Embedded_resource"}
             } = single_error(get_project(["metadata"]))
    end

    test "a fields key on a scalar calculation with arguments is invalid_field_selection" do
      selection = %{args: %{multiplier: 2}, fields: []}

      assert {:error, {:invalid_field_selection, :adjusted_priority, :calculation, [:metadata]}} =
               process([%{metadata: [%{adjusted_priority: selection}]}])

      wire_selection = %{"args" => %{"multiplier" => 2}, "fields" => []}

      # The field type is inspected (":calculation"), as for every
      # invalid_field_selection reason built from a field kind atom.
      assert %{
               "type" => "invalid_field_selection",
               "fields" => ["metadata.adjustedPriority"],
               "path" => ["metadata"],
               "vars" => %{"field" => "metadata.adjustedPriority", "fieldType" => ":calculation"}
             } =
               single_error(
                 get_project([%{"metadata" => [%{"adjustedPriority" => wire_selection}]}])
               )
    end
  end

  describe "embedded input on create and update" do
    test "create casts camelCase embedded input and returns the selection" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_project",
                 "input" => %{
                   "metadata" => %{"category" => "personal", "priorityScore" => 75},
                   "history" => [%{"category" => "old", "isUrgent" => false}]
                 },
                 "fields" => [
                   %{"metadata" => ["category", "priorityScore"]},
                   %{"history" => ["category", "isUrgent"]}
                 ]
               })

      assert data == %{
               "metadata" => %{"category" => "personal", "priorityScore" => 75},
               "history" => [%{"category" => "old", "isUrgent" => false}]
             }
    end

    test "update casts embedded input onto the stored value" do
      project = seed_project!()

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "update_project",
                 "identity" => project.id,
                 "input" => %{
                   "metadata" => %{
                     "category" => "home",
                     "priorityScore" => 10,
                     "isUrgent" => false,
                     "detail" => %{"note" => "second"}
                   }
                 },
                 "fields" => [
                   "id",
                   %{
                     "metadata" => [
                       "category",
                       "priorityScore",
                       "isUrgent",
                       "displayCategory",
                       %{"detail" => ["note", "level"]}
                     ]
                   }
                 ]
               })

      # Ash updates the stored embedded value in place, so the nested `detail`
      # keeps the `level` the input left out.
      assert data == %{
               "id" => project.id,
               "metadata" => %{
                 "category" => "home",
                 "priorityScore" => 10,
                 "isUrgent" => false,
                 "displayCategory" => "category:home",
                 "detail" => %{"note" => "second", "level" => 2}
               }
             }

      assert Ash.get!(AshRpc.Test.Project, project.id).metadata.category == "home"
    end
  end

  describe "an embedded resource as a generic-action argument" do
    defp process_meta(input) do
      run(%{
        "action" => "process_project_meta",
        "input" => input,
        "fields" => ["processed", "priority"]
      })
    end

    defp process_meta_batch(input) do
      run(%{
        "action" => "process_project_meta_batch",
        "input" => input,
        "fields" => ["processed", "priority"]
      })
    end

    test "a plain camelCase map is cast into the embedded resource" do
      assert %{"success" => true, "data" => data} =
               process_meta(%{
                 "meta" => %{
                   "category" => "work",
                   "priorityScore" => 85,
                   "isUrgent" => true,
                   "deadline" => "2026-01-15",
                   "status" => "active",
                   "detail" => %{"note" => "n", "level" => 1}
                 },
                 "options" => %{"verbose" => true}
               })

      assert data == %{"processed" => true, "priority" => 85}
    end

    test "a map with only the required attribute" do
      assert %{"success" => true, "data" => data} =
               process_meta(%{"meta" => %{"category" => "personal"}})

      assert data == %{"processed" => true, "priority" => nil}
    end

    test "a missing embedded argument is required" do
      assert %{"type" => "required", "fields" => ["meta"]} = single_error(process_meta(%{}))
    end

    test "an array of plain maps is cast entry by entry" do
      assert %{"success" => true, "data" => data} =
               process_meta_batch(%{
                 "metas" => [
                   %{"category" => "work", "priorityScore" => 5},
                   %{"category" => "personal", "priorityScore" => 2},
                   %{"category" => "urgent", "priorityScore" => 10}
                 ]
               })

      assert data == [
               %{"processed" => true, "priority" => 5},
               %{"processed" => true, "priority" => 2},
               %{"processed" => true, "priority" => 10}
             ]
    end

    test "an empty array" do
      assert %{"success" => true, "data" => []} = process_meta_batch(%{"metas" => []})
    end

    test "a missing array argument is required" do
      assert %{"type" => "required", "fields" => ["metas"]} =
               single_error(process_meta_batch(%{}))
    end
  end
end
