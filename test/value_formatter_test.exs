# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ValueFormatterTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Runtime, ValueFormatter}

  setup do
    %{runtime: Runtime.new(AshRpc.Test.Profile)}
  end

  test "output: mapped NewType fields use decorated overrides", %{runtime: rt} do
    value = %{word_count_1: 3, is_featured?: true}

    assert ValueFormatter.format(value, AshRpc.Test.PostStats, [], :output, rt) ==
             %{"wordCount1" => 3, "isFeatured" => true}
  end

  test "input: reverse overrides map client keys back", %{runtime: rt} do
    assert ValueFormatter.format(%{"wordCount1" => 3}, AshRpc.Test.PostStats, [], :input, rt) ==
             %{word_count_1: 3}
  end

  test "runtime formatter is used, not config", %{runtime: rt} do
    rt = %{rt | output_formatter: :pascal_case}

    assert %{"ThemeName" => "x"} =
             ValueFormatter.format(%{theme_name: "x"}, AshRpc.Test.PostSettings, [], :output, rt)
  end

  describe "strict input keys" do
    setup do
      rt = Runtime.from_manifest(AshRpc.Test.ManifestBuilder.manifest())
      meta = Ash.Info.Manifest.get_field(rt.resource_lookup, AshRpc.Test.Project, :metadata).type
      %{rt: rt, meta: meta}
    end

    test "an embedded resource resolves client names and throws every other casing", %{
      rt: rt,
      meta: meta
    } do
      assert ValueFormatter.format(%{"priorityScore" => 5}, meta, [], :input, rt) ==
               %{priority_score: 5}

      assert catch_throw(ValueFormatter.format(%{"priority_score" => 5}, meta, [], :input, rt)) ==
               {:unknown_nested_input, [{:unknown_input, "priority_score", []}]}
    end

    test "nested misses carry their path relative to the value", %{rt: rt, meta: meta} do
      value = %{"detail" => %{"Note" => "x"}, "category" => "c"}

      assert catch_throw(ValueFormatter.format(value, meta, [], :input, rt)) ==
               {:unknown_nested_input, [{:unknown_input, "Note", ["detail"]}]}
    end

    test "a type that was never decorated keeps its keys as sent", %{rt: rt} do
      value = %{"fooBar" => 1, "foo_bar" => 2}

      assert ValueFormatter.format(
               value,
               :map,
               [fields: [foo_bar: [type: :integer]]],
               :input,
               rt
             ) == value
    end

    test "custom map-storage input is verbatim", %{rt: rt} do
      palette =
        Ash.Info.Manifest.get_field(rt.resource_lookup, AshRpc.Test.Project, :palette).type

      value = %{"primary" => "a", "secondary" => "b", "accentColor" => "c"}
      assert ValueFormatter.format(value, palette, [], :input, rt) == value
    end
  end
end
