# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Context do
  @moduledoc """
  Actor, tenant and Ash context for one RPC call, independent of transport.

  A `tenant` request param overrides the transport's tenant on every
  transport and is passed to Ash unvalidated; invalid or unauthorized
  tenants surface as normal Ash/policy errors.
  """

  @type t :: %__MODULE__{
          actor: term(),
          tenant: term(),
          context: map(),
          transport: :http | :channel | :direct
        }
  defstruct [:actor, :tenant, context: %{}, transport: :direct]

  @spec from_source(t() | struct()) :: t()
  def from_source(%__MODULE__{} = ctx), do: ctx

  if Code.ensure_loaded?(Plug.Conn) do
    def from_source(%Plug.Conn{} = conn), do: from_conn(conn)
  end

  if Code.ensure_loaded?(Phoenix.Socket) do
    def from_source(%Phoenix.Socket{} = socket), do: from_socket(socket)
  end

  if Code.ensure_loaded?(Plug.Conn) do
    @spec from_conn(Plug.Conn.t()) :: t()
    def from_conn(%Plug.Conn{} = conn) do
      %__MODULE__{
        actor: Ash.PlugHelpers.get_actor(conn),
        tenant: Ash.PlugHelpers.get_tenant(conn),
        context: Ash.PlugHelpers.get_context(conn) || %{},
        transport: :http
      }
    end
  end

  if Code.ensure_loaded?(Phoenix.Socket) do
    @spec from_socket(Phoenix.Socket.t()) :: t()
    def from_socket(%Phoenix.Socket{assigns: assigns}) do
      %__MODULE__{
        actor: assigns[:ash_actor],
        tenant: assigns[:ash_tenant],
        context: assigns[:ash_context] || %{},
        transport: :channel
      }
    end
  end

  @spec put_tenant_param(t(), term()) :: t()
  def put_tenant_param(%__MODULE__{} = ctx, nil), do: ctx
  def put_tenant_param(%__MODULE__{} = ctx, tenant), do: %__MODULE__{ctx | tenant: tenant}
end
