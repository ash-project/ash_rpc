# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ResultOutputTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

  test "nil items in an array attribute survive extraction" do
    assert %{"success" => true, "data" => %{"labels" => ["a", nil, "b"]}} =
             run(%{
               "action" => "create_ledger",
               "input" => %{"labels" => ["a", nil, "b"]},
               "fields" => ["labels"]
             })
  end

  test "array items whose union member wasn't requested are dropped, nil items kept" do
    assert %{"success" => true, "data" => %{"entries" => [%{"number" => 1}, nil]}} =
             run(%{
               "action" => "create_ledger",
               "input" => %{"entries" => [%{"number" => 1}, %{"label" => "x"}, nil]},
               "fields" => [%{"entries" => ["number"]}]
             })
  end

  test "page keys are not formatted through same-named resource fields" do
    run(%{
      "action" => "create_ledger",
      "input" => %{"count" => %{"number" => 3}},
      "fields" => ["id"]
    })

    assert %{"success" => true, "data" => %{"count" => 1, "limit" => 5, "results" => [_]}} =
             run(%{
               "action" => "page_ledgers",
               "page" => %{"limit" => 5, "count" => true},
               "fields" => ["id"]
             })
  end

  describe "Duration values" do
    alias AshRpc.{RequestedFieldsProcessor, ResultProcessor, Runtime}
    alias AshRpc.Test.Project

    defp project_with(attrs) do
      Project
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!()
    end

    defp get_project(fields) do
      run(%{"action" => "get_project", "fields" => fields})
    end

    test "a Duration with days is output as an ISO 8601 string" do
      project = project_with(%{estimate: %Duration{day: 2, hour: 5}})

      assert get_project(["id", "estimate"]) == %{
               "success" => true,
               "data" => %{"id" => project.id, "estimate" => "P2DT5H"}
             }
    end

    test "a zero Duration is output as PT0S" do
      project = project_with(%{estimate: %Duration{}})

      assert get_project(["id", "estimate"]) == %{
               "success" => true,
               "data" => %{"id" => project.id, "estimate" => "PT0S"}
             }
    end

    test "a Duration with microseconds keeps the fractional seconds" do
      project = project_with(%{estimate: %Duration{second: 30, microsecond: {500_000, 6}}})

      assert get_project(["id", "estimate"]) == %{
               "success" => true,
               "data" => %{"id" => project.id, "estimate" => "PT30.500000S"}
             }
    end

    test "each Duration in an array attribute is output as an ISO 8601 string" do
      project =
        project_with(%{breaks: [%Duration{minute: 15}, %Duration{day: 1, hour: 4}, %Duration{}]})

      assert get_project(["id", "breaks"]) == %{
               "success" => true,
               "data" => %{"id" => project.id, "breaks" => ["PT15M", "P1DT4H", "PT0S"]}
             }
    end

    test "Duration fields pass through the extraction template built for them" do
      rt = Runtime.new(@profile)

      project =
        project_with(%{
          estimate: %Duration{hour: 2, minute: 15},
          breaks: [%Duration{minute: 15}]
        })

      assert {:ok, {[:id, :estimate, :breaks], [], template}} =
               RequestedFieldsProcessor.process(rt, Project, :read, ["id", "estimate", "breaks"])

      assert ResultProcessor.process(project, template, Project, rt) == %{
               id: project.id,
               estimate: "PT2H15M",
               breaks: ["PT15M"]
             }
    end
  end
end
