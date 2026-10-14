# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorFormatterTest do
  use ExUnit.Case, async: true

  alias AshRpc.ErrorFormatter

  describe "placeholder rewriting" do
    test "renames placeholders to match renamed vars keys" do
      error = %{
        message: "RPC action %{action_name} not found",
        short_message: "Action not found",
        vars: %{action_name: "list_posts"}
      }

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "RPC action %{actionName} not found",
               "shortMessage" => "Action not found",
               "vars" => %{"actionName" => "list_posts"}
             }
    end

    test "rewrites every placeholder in a message with several vars" do
      error = %{
        message: "%{field_type} %{field} requires field selection",
        vars: %{field_type: "Relationship", field: "author"}
      }

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "%{fieldType} %{field} requires field selection",
               "vars" => %{"fieldType" => "Relationship", "field" => "author"}
             }
    end

    test "rewrites placeholders inside details strings" do
      error = %{
        message: "Union input map does not contain any valid member key",
        vars: %{expected_members: "text, file"},
        details: %{
          suggestion: "Provide exactly one of the following keys: %{expected_members}",
          hint: "no placeholder here"
        }
      }

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "Union input map does not contain any valid member key",
               "vars" => %{"expectedMembers" => "text, file"},
               "details" => %{
                 "suggestion" => "Provide exactly one of the following keys: %{expectedMembers}",
                 "hint" => "no placeholder here"
               }
             }
    end

    test "treats details keys as a dictionary too" do
      error = %{message: "boom", details: %{field_spec: "x", suggestion: "check %{field_spec}"}}

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "boom",
               "details" => %{"suggestion" => "check %{fieldSpec}", "fieldSpec" => "x"}
             }
    end

    test "leaves placeholders alone when they name no dictionary key" do
      error = %{message: "literally %{not_a_var} here", vars: %{field: "x"}}

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "literally %{not_a_var} here",
               "vars" => %{"field" => "x"}
             }
    end

    test "does not rewrite values inside vars" do
      error = %{message: "%{action_name}", vars: %{action_name: "%{action_name}"}}

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "%{actionName}",
               "vars" => %{"actionName" => "%{action_name}"}
             }
    end

    test "a renamed placeholder is never rewritten again" do
      # `a_b` becomes `aB`; a chained rewrite would then match `aB` again.
      error = %{message: "%{a_b} and %{aB}", vars: %{a_b: 1, aB: 2}}

      assert %{"message" => "%{aB} and %{aB}"} = ErrorFormatter.format(error, :camel_case)
    end
  end

  describe "formatter variants" do
    test "pascal_case renames keys and placeholders" do
      error = %{message: "RPC action %{action_name} not found", vars: %{action_name: "x"}}

      assert ErrorFormatter.format(error, :pascal_case) == %{
               "Message" => "RPC action %{ActionName} not found",
               "Vars" => %{"ActionName" => "x"}
             }
    end

    test "snake_case leaves snake_case keys and placeholders alone" do
      error = %{message: "RPC action %{action_name} not found", vars: %{action_name: "x"}}

      assert ErrorFormatter.format(error, :snake_case) == %{
               "message" => "RPC action %{action_name} not found",
               "vars" => %{"action_name" => "x"}
             }
    end
  end

  describe "pass-through" do
    test "errors with no dictionaries are only key-formatted" do
      assert ErrorFormatter.format(
               %{message: "is required", short_message: "Required field"},
               :camel_case
             ) == %{"message" => "is required", "shortMessage" => "Required field"}
    end

    test "non-maps are returned unchanged" do
      assert ErrorFormatter.format("boom", :camel_case) == "boom"
      assert ErrorFormatter.format(nil, :camel_case) == nil
    end

    test "vars values that are not strings survive" do
      error = %{message: "at least %{min_length}", vars: %{min_length: 3, allowed: ["a", "b"]}}

      assert ErrorFormatter.format(error, :camel_case) == %{
               "message" => "at least %{minLength}",
               "vars" => %{"minLength" => 3, "allowed" => ["a", "b"]}
             }
    end
  end
end
