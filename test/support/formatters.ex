# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Formatters do
  @moduledoc false
  # A custom output formatter with no inverse: client names are the
  # internal names upper-cased.
  def upcase(name), do: name |> to_string() |> String.upcase()
end
