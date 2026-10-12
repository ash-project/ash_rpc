# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.GeoPoint do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :tuple,
    constraints: [
      fields: [
        lat_1: [type: :float, allow_nil?: false],
        lng_1: [type: :float, allow_nil?: false],
        is_verified?: [type: :boolean]
      ]
    ]
end
