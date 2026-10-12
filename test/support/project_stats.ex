# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ProjectStats do
  @moduledoc false
  use Ash.TypedStruct

  typed_struct do
    field :view_count, :integer, default: 0
    field :edit_count, :integer, default: 0
    field :all_done?, :boolean

    field :metrics, :map,
      constraints: [
        fields: [
          focus_seconds: [type: :integer, allow_nil?: false],
          efficiency: [type: :float]
        ]
      ]
  end
end
