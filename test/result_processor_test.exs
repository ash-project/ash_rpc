# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ResultProcessorTest do
  use ExUnit.Case, async: true

  alias AshRpc.{ResultProcessor, Runtime}

  setup do
    %{runtime: Runtime.new(AshRpc.Test.Profile)}
  end

  test "normalize_value_for_json/2 makes untyped values JSON-encodable", %{runtime: rt} do
    assert ResultProcessor.normalize_value_for_json([priority: 8, tags: []], rt) ==
             %{"priority" => 8, "tags" => []}

    assert ResultProcessor.normalize_value_for_json(Duration.new!(hour: 1), rt) == "PT1H"
  end
end
