# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PostStats do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        word_count_1: [type: :integer],
        is_featured?: [type: :boolean]
      ]
    ]
end
