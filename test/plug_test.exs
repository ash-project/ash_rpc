# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.PlugTest do
  use ExUnit.Case, async: true

  defp post(params), do: Plug.Test.conn(:post, "/rpc", params)

  defmodule ErrorHandlingRouter do
    @moduledoc false
    use Plug.Router
    use Plug.ErrorHandler

    plug(:match)
    plug(:dispatch)

    post("/rpc", do: AshRpc.Plug.run(conn, AshRpc.Test.Profile))
  end

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

  test "pipeline exceptions respond 200 with a wire error" do
    {conn, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        AshRpc.Plug.run(post(%{"action" => %{"not" => "a string"}}), AshRpc.Test.Profile)
      end)

    assert conn.status == 200
    assert %{"success" => false, "errors" => [_ | _]} = Jason.decode!(conn.resp_body)
  end

  test "untyped data Jason can't encode raises, and Plug answers 500" do
    error =
      assert_raise Protocol.UndefinedError, fn ->
        AshRpc.Plug.run(post(%{"action" => "catalog_untyped_records_map"}), AshRpc.Test.Profile)
      end

    assert Exception.message(error) =~ "Jason.Encoder"
    assert Plug.Exception.status(error) == 500

    assert_raise Plug.Conn.WrapperError, fn ->
      ErrorHandlingRouter.call(
        post(%{"action" => "catalog_untyped_records_map"}),
        ErrorHandlingRouter.init([])
      )
    end

    assert_received {_ref, {500, _headers, "Something went wrong"}}
  end
end
