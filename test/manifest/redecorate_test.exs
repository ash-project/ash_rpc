# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.RedecorateTest do
  use ExUnit.Case, async: true

  alias AshRpc.Manifest

  setup_all do
    %{manifest: AshRpc.Test.ManifestBuilder.manifest()}
  end

  test "overrides formatters and keeps the stored mapping source", %{manifest: m} do
    r = Manifest.redecorate(m, output_formatter: :pascal_case, input_formatter: :snake_case)

    assert Manifest.output_formatter(r) == :pascal_case
    assert Manifest.input_formatter(r) == :snake_case
    assert Manifest.mapping_source(r) == AshRpc.Test.MappingSource

    assert AshRpc.Manifest.Custom.field_names(Manifest.resource_lookup(r)[AshRpc.Test.Author])[
             :name
           ] == "Name"

    assert AshRpc.Manifest.Custom.field_names(Manifest.resource_lookup(r)[AshRpc.Test.Author])[
             :is_active?
           ] == "isActive"
  end

  test "expected input keys follow the new output formatter", %{manifest: m} do
    r = Manifest.redecorate(m, output_formatter: :snake_case)
    action = Manifest.action_lookup(r)[{AshRpc.Test.Post, :create}]
    assert Map.has_key?(AshRpc.Manifest.Custom.action_expected_input_keys(action), "view_count")
  end

  test "unknown option keys are ignored", %{manifest: m} do
    assert Manifest.redecorate(m, bogus: 1) == m
  end

  test "an unloaded mapping source raises", %{manifest: m} do
    broken = put_in(m.custom.ash_rpc.mapping_source, :"Elixir.Does.Not.Exist")
    assert_raise ArgumentError, ~r/Does.Not.Exist/, fn -> Manifest.redecorate(broken, []) end
  end
end
