# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.BoundaryTest do
  use ExUnit.Case, async: true

  # ash_rpc must not reference any extension built on it. The consumer names
  # are assembled from parts so this file doesn't match its own check.
  @forbidden ["Ash" <> "Typescript", "ash_" <> "typescript"]

  @lib Path.expand("../lib", __DIR__)

  test "nothing in ash_rpc references its consumers" do
    assert violating_files() == []
  end

  defp violating_files do
    [Path.join(@lib, "ash_rpc.ex") | Path.wildcard(Path.join(@lib, "ash_rpc/**/*.ex"))]
    |> Enum.filter(&(File.exists?(&1) and String.contains?(File.read!(&1), @forbidden)))
    |> Enum.map(&Path.relative_to(&1, @lib))
    |> Enum.sort()
  end
end
