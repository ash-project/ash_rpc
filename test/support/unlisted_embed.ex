# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.UnlistedEmbed do
  @moduledoc """
  An embedded resource nothing in the fixture domain references, so it never
  enters the manifest: a resource struct outside `resource_lookup`.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :label, :string, public?: true
    attribute :hidden, :string
  end
end
