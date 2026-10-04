# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.NameCollisionError do
  @moduledoc "Raised during decoration when two fields or inputs map to the same client name."
  defexception [:message]
end
