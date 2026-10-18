# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.SessionHolder do
  @moduledoc false
  # An embedded resource with a public plain-struct attribute: reaching it
  # from a wire entrypoint reaches an untyped struct.
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :label, :string, public?: true

    attribute :session, :struct,
      constraints: [instance_of: AshRpc.Test.PlainSession],
      public?: true
  end
end
