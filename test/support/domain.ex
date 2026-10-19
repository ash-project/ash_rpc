# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshRpc.Test.Account
    resource AshRpc.Test.Author
    resource AshRpc.Test.Catalog
    resource AshRpc.Test.Comment
    resource AshRpc.Test.Intake
    resource AshRpc.Test.Ledger
    resource AshRpc.Test.Note
    resource AshRpc.Test.Place
    resource AshRpc.Test.PointLog
    resource AshRpc.Test.NoteReply
    resource AshRpc.Test.Post
    resource AshRpc.Test.PostTag
    resource AshRpc.Test.Project
    resource AshRpc.Test.ProjectNote
    resource AshRpc.Test.Secret
    resource AshRpc.Test.SessionLog
    resource AshRpc.Test.SessionOwner
    resource AshRpc.Test.Tag
    resource AshRpc.Test.Voucher
    resource AshRpc.Test.Widget
  end
end
