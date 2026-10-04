# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.UnionInputTest do
  use ExUnit.Case, async: true

  # Ledger.count is a union of `number: :integer` and `label: :string`.
  @profile AshRpc.Test.Profile

  defp create_ledger(count) do
    AshRpc.run_action(@profile, %AshRpc.Context{}, %{
      "action" => "create_ledger",
      "input" => %{"count" => count},
      "fields" => ["id", %{"count" => ["number", "label"]}]
    })
  end

  describe "wrapped member input" do
    test "a map with one member key selects that member" do
      assert %{"success" => true, "data" => %{"count" => %{"number" => 3}}} =
               create_ledger(%{"number" => 3})

      assert %{"success" => true, "data" => %{"count" => %{"label" => "x"}}} =
               create_ledger(%{"label" => "x"})
    end

    test "output selection must name members" do
      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, %AshRpc.Context{}, %{
                 "action" => "create_ledger",
                 "input" => %{"count" => %{"label" => "x"}},
                 "fields" => ["count"]
               })

      assert %{"type" => "requires_field_selection", "fields" => ["count"]} = error
    end
  end

  describe "invalid_union_input" do
    test "a bare value is not_a_map" do
      assert %{"success" => false, "errors" => [error]} = create_ledger(3)

      assert %{
               "type" => "invalid_union_input",
               "message" => "Union input must be a map with exactly one member key",
               "details" => %{
                 "suggestion" => "Provide union input in the format: {\"member_name\": value}"
               }
             } = error
    end

    test "a map without a member key lists the expected members" do
      assert %{"success" => false, "errors" => [error]} = create_ledger(%{"other" => 1})

      assert %{
               "type" => "invalid_union_input",
               "message" => "Union input map does not contain any valid member key",
               "vars" => %{"expectedMembers" => "number, label"},
               "details" => %{"expectedMembers" => ["number", "label"]}
             } = error
    end

    test "a map with several member keys is rejected" do
      assert %{"success" => false, "errors" => [error]} =
               create_ledger(%{"number" => 1, "label" => "x"})

      assert %{
               "type" => "invalid_union_input",
               "message" => "Union input map contains multiple member keys: %{foundKeys}",
               "vars" => %{"expectedMembers" => "number, label", "foundKeys" => "number, label"}
             } = error
    end
  end
end
