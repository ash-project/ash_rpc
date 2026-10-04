# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.DefaultErrorHandler do
  @moduledoc """
  Default `AshRpc.ErrorHandler`: returns errors unchanged, leaving `vars`
  interpolation into `message` to the client.
  """

  @behaviour AshRpc.ErrorHandler

  @impl true
  def handle_error(error, _context), do: error
end
