# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.SessionLog do
  @moduledoc false
  # Records that carry an untyped struct: the read returns them, the create
  # accepts one, and the generic `ping` does neither. No wire entrypoint by
  # default: decoration rejects the read and the create.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true

    attribute :session, :struct,
      constraints: [instance_of: AshRpc.Test.PlainSession],
      public?: true
  end

  actions do
    defaults [:read, create: [:session]]

    # A generic action returns no records, so the records aren't checked.
    action :ping, :boolean do
      run fn _input, _context -> {:ok, true} end
    end
  end
end

defmodule AshRpc.Test.SessionOwner do
  @moduledoc false
  # Reaches `SessionLog.session` only through a relationship to an exposed
  # resource. No wire entrypoint by default: decoration rejects its read.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
  end

  relationships do
    belongs_to :log, AshRpc.Test.SessionLog, public?: true
  end

  actions do
    defaults [:read]
  end
end
