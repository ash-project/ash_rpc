# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.TreeNode do
  @moduledoc false
  # A self-referential typed map: the untyped-struct walk must terminate on it.
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        label: [type: :string],
        children: [type: {:array, AshRpc.Test.TreeNode}, init?: false]
      ]
    ]
end
