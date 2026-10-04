# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.UnconstrainedMapTest do
  use ExUnit.Case, async: true

  alias AshRpc.ResultProcessor

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp runtime, do: AshRpc.Runtime.new(@profile)

  defp seed_post(data) do
    Ash.create!(AshRpc.Test.Post, %{title: "Seeded", data: data})
  end

  defp initial_data do
    %{
      "initial_key" => "initial_value",
      "count" => 42,
      "nested" => %{"inner_key" => "inner_value"}
    }
  end

  describe "data attribute" do
    test "create round-trips the map verbatim, snake_case and nested keys untouched" do
      data = %{
        "snake_key" => "value",
        "camelKey" => true,
        "numbers" => [1, 2, 3],
        "mixed_types" => %{
          "float_value" => 42.5,
          "boolean_value" => false,
          "null_value" => nil,
          "array" => [1, "two", 3.0],
          "deep" => %{"deeper_key" => %{"deepest_key" => "value"}}
        },
        "array_of_objects" => [%{"item_id" => 1}, %{"item_id" => 2}]
      }

      assert %{"success" => true, "data" => result} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "create_post",
                 "input" => %{"title" => "With data", "data" => data},
                 "fields" => ["id", "title", "data"]
               })

      assert result["title"] == "With data"
      assert result["data"] == data
    end

    test "update replaces the map wholesale, keys untouched" do
      post = seed_post(initial_data())
      replacement = %{"replaced_key" => "replaced_value", "direct_update" => true}

      assert %{"success" => true, "data" => %{"data" => data}} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "update_post",
                 "identity" => post.id,
                 "input" => %{"data" => replacement},
                 "fields" => ["id", "data"]
               })

      assert data == replacement
    end
  end

  describe "map argument on an update (merge_post_data)" do
    test "merges the argument into the existing data" do
      post = seed_post(initial_data())

      additional = %{
        "new_key" => "new_value",
        "flag" => false,
        "nested_object" => %{"level_2" => %{"level_3" => "deep_value"}}
      }

      assert %{"success" => true, "data" => %{"data" => data}} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "merge_post_data",
                 "identity" => post.id,
                 "input" => %{"data" => additional},
                 "fields" => ["id", "data"]
               })

      assert data == Map.merge(initial_data(), additional)
    end

    test "a nil argument leaves the existing data unchanged" do
      post = seed_post(initial_data())

      # An update whose only change is skipped returns the stored record
      assert %{"success" => true, "data" => %{"data" => data}} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "merge_post_data",
                 "identity" => post.id,
                 "input" => %{"data" => nil},
                 "fields" => ["id", "data"]
               })

      assert data == initial_data()
    end

    test "merging into nil data sets the argument" do
      post = seed_post(nil)

      assert %{"success" => true, "data" => %{"data" => data}} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "merge_post_data",
                 "identity" => post.id,
                 "input" => %{"data" => %{"first_key" => "first_value", "count" => 1}},
                 "fields" => ["id", "data"]
               })

      assert data == %{"first_key" => "first_value", "count" => 1}
    end
  end

  describe "generic action with :map in and out (echo_map)" do
    test "returns the payload verbatim without a fields selection" do
      payload = %{
        "snake_key" => "value",
        "camelKey" => 1,
        "enabled" => false,
        "nested" => %{"inner_key" => [%{"leaf_key" => nil}]}
      }

      assert %{"success" => true, "data" => data} =
               AshRpc.run_action(@profile, ctx(), %{
                 "action" => "echo_map",
                 "input" => %{"payload" => payload}
               })

      assert data == payload
    end
  end

  describe "ResultProcessor.extract_value/5 on plain maps with a field template" do
    test "regression: keeps a false value under an atom key" do
      assert ResultProcessor.extract_value(%{enabled: false}, nil, [], [:enabled], runtime()) ==
               %{enabled: false}
    end

    test "regression: keeps a false value under a string key" do
      assert ResultProcessor.extract_value(
               %{"enabled" => false},
               nil,
               [],
               [:enabled],
               runtime()
             ) == %{enabled: false}
    end

    test "regression: keeps a false value under nested atom keys" do
      assert ResultProcessor.extract_value(
               %{settings: %{enabled: false}},
               nil,
               [],
               [{:settings, [:enabled]}],
               runtime()
             ) == %{settings: %{enabled: false}}
    end

    test "regression: keeps a false value under nested string keys" do
      assert ResultProcessor.extract_value(
               %{"settings" => %{"enabled" => false}},
               nil,
               [],
               [{:settings, [:enabled]}],
               runtime()
             ) == %{settings: %{enabled: false}}
    end

    test "regression: an atom key holding false wins over the string key" do
      assert ResultProcessor.extract_value(
               %{:enabled => false, "enabled" => true},
               nil,
               [],
               [:enabled],
               runtime()
             ) == %{enabled: false}
    end

    test "regression: a missing atom key falls back to the string key" do
      assert ResultProcessor.extract_value(%{"count" => 3}, nil, [], [:count], runtime()) ==
               %{count: 3}
    end
  end
end
