# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Voucher do
  @moduledoc false
  # Not exposed by the mapping source. Taken as a struct input by
  # `Catalog.redeem_voucher`, so decoration gives it formatter-only names;
  # `Post.vouchers` still stays closed to selection.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :voucher_code, :string, public?: true
    attribute :post_id, :uuid, public?: true
  end

  actions do
    defaults [:read, create: [:voucher_code, :post_id]]
  end
end
