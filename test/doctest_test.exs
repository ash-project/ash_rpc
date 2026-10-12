# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.DoctestTest do
  use ExUnit.Case, async: true

  doctest AshRpc.ErrorFormatter
  doctest AshRpc.FieldExtractor
  doctest AshRpc.FieldFormatter
  doctest AshRpc.FieldProcessing.FieldSelector
  doctest AshRpc.Introspection
end
