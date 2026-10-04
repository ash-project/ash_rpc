# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.CommentAttachment do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :url, :string, allow_nil?: false, public?: true
  end

  calculations do
    calculate :label, :string, expr("file:" <> url), public?: true
  end
end
