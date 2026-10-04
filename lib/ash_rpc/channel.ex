# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule AshRpc.Channel do
    @moduledoc """
    Injects RPC event handlers into a Phoenix channel:

        defmodule MyAppWeb.RpcChannel do
          use Phoenix.Channel
          use AshRpc.Channel, profile: MyApp.RpcProfile

          def join("rpc:" <> _, _payload, socket), do: {:ok, socket}
        end

    Handles `"run"` and `"validate"` (always `{:reply, {:ok, result}, socket}`;
    success or failure is in the body, and pipeline exceptions become wire
    errors) and replies `{:error, %{reason: "Unknown event: …", payload: …}}`
    to anything else. Actor, tenant and context come from
    `socket.assigns[:ash_actor | :ash_tenant | :ash_context]`; a `tenant`
    param overrides the tenant. The app owns `join/3`, topics and socket auth.

    The injected `handle_in/3` includes a catch-all, so don't define further
    `handle_in/3` clauses. For extra events, skip the macro and call
    `run/3` / `validate/3` from your own `handle_in/3`.
    """

    defmacro __using__(opts) do
      profile = Keyword.fetch!(opts, :profile)

      quote do
        @impl true
        def handle_in("run", params, socket),
          do: {:reply, {:ok, AshRpc.Channel.run(unquote(profile), socket, params)}, socket}

        def handle_in("validate", params, socket),
          do: {:reply, {:ok, AshRpc.Channel.validate(unquote(profile), socket, params)}, socket}

        def handle_in(event, payload, socket),
          do: {:reply, {:error, %{reason: "Unknown event: #{event}", payload: payload}}, socket}
      end
    end

    @spec run(module(), Phoenix.Socket.t(), map()) :: map()
    def run(profile, socket, params) do
      AshRpc.run_action(profile, socket, params)
    rescue
      e -> AshRpc.error_response(profile, e)
    end

    @spec validate(module(), Phoenix.Socket.t(), map()) :: map()
    def validate(profile, socket, params) do
      AshRpc.validate_action(profile, socket, params)
    rescue
      e -> AshRpc.error_response(profile, e)
    end
  end
end
