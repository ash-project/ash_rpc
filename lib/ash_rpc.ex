# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc do
  @moduledoc """
  Client-agnostic RPC runtime for Ash.

  Each extension mounts its own endpoint and calls these functions with its
  `AshRpc.Profile`. Responses are client-formatted maps (never tuples):
  `%{"success" => true, "data" => …}` or `%{"success" => false, "errors" => […]}`,
  with key casing from the manifest's output formatter. Exceptions raised
  while handling a request are returned as failure responses too.
  """

  alias AshRpc.{Context, Pipeline, Runtime, Validation}

  @type source :: Plug.Conn.t() | Phoenix.Socket.t() | Context.t()
  @type opts :: [manifest: Ash.Info.Manifest.t(), entrypoint: AshRpc.Entrypoint.t()]

  @spec run_action(module(), source(), map(), opts()) :: map()
  def run_action(profile, source, params, opts \\ []) do
    runtime = Runtime.new(profile, opts)

    case Pipeline.parse_request(runtime, Context.from_source(source), params, opts) do
      {:ok, request} ->
        with {:ok, ash_result} <- Pipeline.execute_ash_action(request),
             {:ok, processed} <- Pipeline.process_result(ash_result, request) do
          Pipeline.format_output(%{success: true, data: processed}, request)
        else
          {:error, reason} ->
            Pipeline.error_response(runtime, reason, Pipeline.error_scope(request))
        end

      {:error, reason} ->
        Pipeline.error_response(runtime, reason, nil)
    end
  rescue
    e -> error_response(profile, e, opts)
  end

  @spec validate_action(module(), source(), map(), opts()) :: map()
  def validate_action(profile, source, params, opts \\ []) do
    runtime = Runtime.new(profile, opts)
    opts = Keyword.put(opts, :validation_mode?, true)

    case Pipeline.parse_request(runtime, Context.from_source(source), params, opts) do
      {:ok, request} -> request |> Validation.validate() |> Pipeline.format_output(request)
      {:error, reason} -> Pipeline.error_response(runtime, reason, nil)
    end
  rescue
    e -> error_response(profile, e, opts)
  end

  @doc "Client-formatted failure response for a pipeline error reason or exception."
  @spec error_response(module(), term(), opts()) :: map()
  def error_response(profile, reason, opts \\ []),
    do: Pipeline.error_response(Runtime.new(profile, opts), reason, nil)

  @doc "Client-formatted failure response for already-built error maps."
  @spec failure_response(module(), [map()], opts()) :: map()
  def failure_response(profile, errors, opts \\ []) when is_list(errors),
    do: Pipeline.format_response(Runtime.new(profile, opts), %{success: false, errors: errors})
end
