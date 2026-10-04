# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshRpc.Plug do
    @moduledoc """
    Plug helpers that run an RPC request and send the JSON response.

        def run(conn, _params), do: AshRpc.Plug.run(conn, MyApp.RpcProfile)
        def validate(conn, _params), do: AshRpc.Plug.validate(conn, MyApp.RpcProfile)

    Always responds 200; success or failure is in the body. Requires
    `conn.params` to be parsed (e.g. `Plug.Parsers` with `:json`).
    """

    @spec run(Plug.Conn.t(), module()) :: Plug.Conn.t()
    def run(conn, profile), do: send_json(conn, AshRpc.run_action(profile, conn, conn.params))

    @spec validate(Plug.Conn.t(), module()) :: Plug.Conn.t()
    def validate(conn, profile),
      do: send_json(conn, AshRpc.validate_action(profile, conn, conn.params))

    defp send_json(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode_to_iodata!(body))
    end
  end
end
