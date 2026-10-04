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
end
