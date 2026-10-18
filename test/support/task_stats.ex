# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.TaskStats do
  @moduledoc false
  use Ash.TypedStruct

  typed_struct do
    field :total_count, :integer, default: 0
    field :completed?, :boolean
    field :is_urgent?, :boolean, default: false
    field :average_duration, :float
  end
end

defmodule AshRpc.Test.EmptyStats do
  @moduledoc false
  # A TypedStruct with no fields: typed (an explicit empty field list), so
  # decoration accepts it.
  use Ash.TypedStruct

  typed_struct do
  end
end
