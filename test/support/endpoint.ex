# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Socket do
  @moduledoc false
  use Phoenix.Socket

  @impl true
  def connect(_params, socket, _info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end

defmodule AshRpc.Test.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :ash_rpc
end

defmodule AshRpc.Test.RpcChannel do
  @moduledoc false
  use Phoenix.Channel
  use AshRpc.Channel, profile: AshRpc.Test.Profile

  @impl true
  def join("rpc:" <> _, _payload, socket), do: {:ok, socket}
end
