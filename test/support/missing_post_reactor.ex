# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.MissingPostReactor do
  @moduledoc false
  # Runs a generic action whose only step fails with NotFound. Ash returns the
  # failure as an error class wrapping a Reactor RunStepError.
  use Reactor

  input(:post_id)

  step :lookup do
    argument :post_id, input(:post_id)

    run fn _arguments, _context ->
      {:error, Ash.Error.Query.NotFound.exception(resource: AshRpc.Test.Post)}
    end
  end
end
