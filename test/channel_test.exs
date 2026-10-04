# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  @endpoint AshRpc.Test.Endpoint

  setup_all do
    start_supervised!({Phoenix.PubSub, name: AshRpc.Test.PubSub})
    start_supervised!(AshRpc.Test.Endpoint)
    # Build the cached fixture manifest up front so the first push isn't slowed
    # past assert_reply's timeout.
    _ = AshRpc.Test.ManifestBuilder.manifest()
    :ok
  end

  setup do
    {:ok, _, socket} =
      AshRpc.Test.Socket
      |> socket("user", %{ash_actor: nil, ash_tenant: nil})
      |> subscribe_and_join(AshRpc.Test.RpcChannel, "rpc:lobby")

    %{socket: socket}
  end

  test "run replies ok with the result body", %{socket: socket} do
    ref =
      push(socket, "run", %{
        "action" => "create_post",
        "input" => %{"title" => "c"},
        "fields" => ["title"]
      })

    assert_reply(ref, :ok, %{"success" => true, "data" => %{"title" => "c"}})
  end

  test "validate replies ok with failures in the body", %{socket: socket} do
    ref = push(socket, "validate", %{"action" => "create_post", "input" => %{}})
    assert_reply(ref, :ok, %{"success" => false})
  end

  test "pipeline exceptions become wire errors without crashing", %{socket: socket} do
    ref = push(socket, "run", %{"action" => %{"not" => "a string"}})
    assert_reply(ref, :ok, %{"success" => false, "errors" => [_ | _]})
    assert Process.alive?(socket.channel_pid)
  end

  test "unknown events reply error", %{socket: socket} do
    ref = push(socket, "nope", %{"a" => 1})
    assert_reply(ref, :error, %{reason: "Unknown event: nope", payload: %{"a" => 1}})
  end
end
