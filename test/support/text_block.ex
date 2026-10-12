# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.TextBlock do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :text, :string, allow_nil?: false, public?: true
    attribute :word_count, :integer, public?: true
    attribute :content_type, :string, public?: true
  end

  calculations do
    calculate :display_text, :string, expr("text:" <> text), public?: true
  end
end
