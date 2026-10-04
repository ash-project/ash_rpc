# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PostSettings do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :allow_comments, :boolean, default: true, public?: true
    attribute :theme_name, :string, public?: true
  end
end
