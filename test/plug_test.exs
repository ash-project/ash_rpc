# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.PlugTest do
  use ExUnit.Case, async: true

  defp post(params), do: Plug.Test.conn(:post, "/rpc", params)

  test "run/2 responds 200 with the JSON envelope" do
    conn =
      AshRpc.Plug.run(
        post(%{"action" => "create_post", "input" => %{"title" => "x"}, "fields" => ["title"]}),
        AshRpc.Test.Profile
      )

    assert conn.status == 200
    assert ["application/json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert %{"success" => true, "data" => %{"title" => "x"}} = Jason.decode!(conn.resp_body)
  end

  test "validate/2 responds 200 with success false on errors" do
    conn =
      AshRpc.Plug.validate(
        post(%{"action" => "create_post", "input" => %{}}),
        AshRpc.Test.Profile
      )

    assert conn.status == 200
    assert %{"success" => false, "errors" => [_ | _]} = Jason.decode!(conn.resp_body)
  end
end
