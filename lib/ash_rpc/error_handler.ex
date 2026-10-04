# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorHandler do
  @moduledoc """
  Behaviour for custom RPC error handlers.

  Error handlers allow you to customize how errors are transformed
  and presented to clients. They are called after the
  Error protocol transformation but before the final response.

  ## Context

  The context passed to `handle_error/2` is the request's Ash context map
  (`%AshRpc.Context{}.context`: the `Ash.PlugHelpers` context on a conn, or
  the `ash_context` socket assign). Errors raised before the entrypoint
  resolves, and exceptions rescued at the top level, get `%{}`.

  The domain is not part of the context: the profile picks a handler per
  domain through `error_handler/1`.

  ## Example Implementation

      defmodule MyApp.CustomErrorHandler do
        @behaviour AshRpc.ErrorHandler

        def handle_error(error, context) do
          # Add custom error tracking
          Logger.error("RPC Error: \#{inspect(error)}")

          # Customize error format
          error
          |> Map.put(:timestamp, DateTime.utc_now())
          |> Map.update(:message, "Error", &translate_message/1)
        end

        defp translate_message(message) do
          # Custom translation logic
          message
        end
      end
  """

  @doc """
  Handles an error by transforming it before sending to the client.

  Receives an error map that has already been processed by the Error protocol,
  and a context map with additional information.

  Should return a modified error map or nil to filter out the error.
  """
  @callback handle_error(error :: map(), context :: map()) :: map() | nil
end
