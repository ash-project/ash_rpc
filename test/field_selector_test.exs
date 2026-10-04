# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldSelectorTest do
  use ExUnit.Case, async: true

  alias AshRpc.{RequestedFieldsProcessor, Runtime}

  setup do
    %{runtime: Runtime.new(AshRpc.Test.Profile)}
  end

  test "selects attributes and an exposed relationship", %{runtime: rt} do
    fields =
      RequestedFieldsProcessor.atomize_requested_fields(
        ["id", "title", %{"author" => ["name", "isActive"]}],
        AshRpc.Test.Post,
        rt
      )

    assert {:ok, {select, load, _template}} =
             RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :read, fields)

    assert :title in select
    assert [{:author, _}] = load
  end

  test "a relationship to an unexposed resource is unknown_field", %{runtime: rt} do
    fields =
      RequestedFieldsProcessor.atomize_requested_fields(
        [%{"secret" => ["code"]}],
        AshRpc.Test.Post,
        rt
      )

    assert {:error, {:unknown_field, :secret, AshRpc.Test.Post, _path}} =
             RequestedFieldsProcessor.process(rt, AshRpc.Test.Post, :read, fields)
  end
end
