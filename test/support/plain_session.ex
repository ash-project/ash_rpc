# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PlainSession do
  @moduledoc false
  # A plain struct with no Ash type behind it: the manifest knows its module
  # but no field names or types. `token` stands in for data that must never
  # reach a client.
  defstruct [:user_id, :token]
end

defmodule AshRpc.Test.PlainSessionType do
  @moduledoc false
  # A NewType over `:struct` that names a plain struct and declares no fields.
  use Ash.Type.NewType, subtype_of: :struct, constraints: [instance_of: AshRpc.Test.PlainSession]
end
