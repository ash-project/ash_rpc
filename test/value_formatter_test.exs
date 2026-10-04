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
end
