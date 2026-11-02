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

  describe "invalid_union_input in calculation arguments and filter values" do
    defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

    defp no_member_key(path) do
      %{
        "type" => "invalid_union_input",
        "message" => "Union input map does not contain any valid member key",
        "shortMessage" => "Invalid union input",
        "vars" => %{"expectedMembers" => "number, label"},
        "fields" => [],
        "path" => path,
        "details" => %{
          "expectedMembers" => ["number", "label"],
          "suggestion" => "Provide exactly one of the following keys: %{expectedMembers}",
          "hint" => AshRpc.Profile.default_stale_client_hint()
        }
      }
    end

    defp multiple_member_keys(path) do
      %{
        "type" => "invalid_union_input",
        "message" => "Union input map contains multiple member keys: %{foundKeys}",
        "shortMessage" => "Invalid union input",
        "vars" => %{"expectedMembers" => "number, label", "foundKeys" => "number, label"},
        "fields" => [],
        "path" => path,
        "details" => %{
          "suggestion" =>
            "Provide exactly one member key, not multiple. Choose one of: %{expectedMembers}"
        }
      }
    end

    test "a calculation argument value in field selection" do
      for {choice, expected} <- [
            {%{"bogus" => 1}, no_member_key(["choiceLabel", "args", "choice"])},
            {%{"number" => 1, "label" => "x"},
             multiple_member_keys(["choiceLabel", "args", "choice"])}
          ] do
        fields = ["id", %{"choiceLabel" => %{"args" => %{"choice" => choice}}}]

        assert %{"success" => false, "errors" => [^expected]} =
                 run(%{"action" => "list_ledgers", "fields" => fields})
      end
    end

    test "a calculation argument value in a filter input" do
      for {choice, expected} <- [
            {%{"bogus" => 1}, no_member_key(["filter", "choiceLabel", "input", "choice"])},
            {%{"number" => 1, "label" => "x"},
             multiple_member_keys(["filter", "choiceLabel", "input", "choice"])}
          ] do
        filter = %{"choiceLabel" => %{"input" => %{"choice" => choice}, "eq" => "1"}}

        assert %{"success" => false, "errors" => [^expected]} =
                 run(%{"action" => "list_ledgers", "fields" => ["id"], "filter" => filter})
      end
    end

    test "a filter operator value" do
      for {value, expected} <- [
            {%{"bogus" => 1}, no_member_key(["filter", "count", "eq"])},
            {%{"number" => 1, "label" => "x"}, multiple_member_keys(["filter", "count", "eq"])}
          ] do
        filter = %{"count" => %{"eq" => value}}

        assert %{"success" => false, "errors" => [^expected]} =
                 run(%{"action" => "list_ledgers", "fields" => ["id"], "filter" => filter})
      end
    end

    test "valid union values select and filter" do
      create_ledger(%{"number" => 3})

      fields = ["id", %{"choiceLabel" => %{"args" => %{"choice" => %{"label" => "x"}}}}]

      assert %{"success" => true, "data" => [%{"choiceLabel" => "x"} | _]} =
               run(%{"action" => "list_ledgers", "fields" => fields})

      filter = %{"choiceLabel" => %{"input" => %{"choice" => %{"number" => 7}}, "eq" => "7"}}

      assert %{"success" => true, "data" => [_ | _]} =
               run(%{"action" => "list_ledgers", "fields" => ["id"], "filter" => filter})
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

    test "a member key in a non-client casing is not a member" do
      assert %{"success" => false, "errors" => [error]} =
               AshRpc.run_action(@profile, %AshRpc.Context{}, %{
                 "action" => "create_widget",
                 "input" => %{"content" => %{"priority_value" => 3}},
                 "fields" => ["id"]
               })

      assert %{"type" => "invalid_union_input"} = error
    end
  end
end
