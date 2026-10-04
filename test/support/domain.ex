# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshRpc.Test.Author
    resource AshRpc.Test.Comment
    resource AshRpc.Test.Ledger
    resource AshRpc.Test.Note
    resource AshRpc.Test.NoteReply
    resource AshRpc.Test.Post
    resource AshRpc.Test.PostTag
    resource AshRpc.Test.Secret
    resource AshRpc.Test.Tag
  end
end
