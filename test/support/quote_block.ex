# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.QuoteBlock do
  @moduledoc false
  # An embedded resource the test mapping source does not expose. It still
  # gets formatter-only client names; the mapping source raises if asked for
  # its overrides, so decoration must not call it for this module.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :text, :string, allow_nil?: false, public?: true
    attribute :attributed_to, :string, public?: true
    attribute :word_count, :integer, public?: true
  end
end
