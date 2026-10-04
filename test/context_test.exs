# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ContextTest do
  use ExUnit.Case, async: true

  alias AshRpc.Context

  test "from_conn/1 reads Ash.PlugHelpers" do
    conn =
      Plug.Test.conn(:post, "/rpc/run")
      |> Ash.PlugHelpers.set_actor(%{id: 1})
      |> Ash.PlugHelpers.set_tenant("t1")
      |> Ash.PlugHelpers.set_context(%{a: 1})

    assert %Context{actor: %{id: 1}, tenant: "t1", context: %{a: 1}, transport: :http} =
             Context.from_conn(conn)
  end

  test "from_socket/1 reads ash_* assigns" do
    socket = %Phoenix.Socket{
      assigns: %{ash_actor: %{id: 2}, ash_tenant: "t2", ash_context: %{b: 2}}
    }

    assert %Context{actor: %{id: 2}, tenant: "t2", context: %{b: 2}, transport: :channel} =
             Context.from_socket(socket)
  end

  test "from_socket/1 defaults context to %{}" do
    assert %Context{context: %{}} = Context.from_socket(%Phoenix.Socket{assigns: %{}})
  end

  test "put_tenant_param/2 overrides, nil keeps" do
    ctx = %Context{tenant: "t1"}
    assert Context.put_tenant_param(ctx, "t9").tenant == "t9"
    assert Context.put_tenant_param(ctx, nil).tenant == "t1"
  end
end
