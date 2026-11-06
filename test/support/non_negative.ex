# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.NonNegative do
  @moduledoc false
  # A constrained NewType: its own cast_input applies `min: 0`.
  use Ash.Type.NewType, subtype_of: :integer, constraints: [min: 0]
end
