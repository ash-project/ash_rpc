# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PartialErrorHandler do
  @moduledoc false

  # A redaction hook written the usual way: it matches only the error shapes
  # its author anticipated, so any other error raises FunctionClauseError.
  def handle_error(%{type: "invalid_attribute"} = error, _context) do
    %{error | message: "Invalid value.", short_message: "Invalid value", vars: %{}}
  end

  def raise_error(_error, _context), do: raise("handler crashed")

  def throw_error(_error, _context), do: throw(:handler_threw)
end

defmodule AshRpc.Test.PartialHandlerProfile do
  @moduledoc false
  use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder

  @impl AshRpc.Profile
  def error_handler(_domain), do: {AshRpc.Test.PartialErrorHandler, :handle_error, []}
end

defmodule AshRpc.Test.RaisingHandlerProfile do
  @moduledoc false
  use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder

  @impl AshRpc.Profile
  def error_handler(_domain), do: {AshRpc.Test.PartialErrorHandler, :raise_error, []}
end

defmodule AshRpc.Test.ThrowingHandlerProfile do
  @moduledoc false
  use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder

  @impl AshRpc.Profile
  def error_handler(_domain), do: {AshRpc.Test.PartialErrorHandler, :throw_error, []}
end
