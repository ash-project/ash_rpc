# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.RuntimeTest do
  use ExUnit.Case, async: true

  alias AshRpc.Runtime

  defmodule Undecorated do
    use AshRpc.Profile

    @impl AshRpc.Profile
    def manifest do
      AshRpc.Test.ManifestBuilder.generate!([{AshRpc.Test.Post, :read}])
    end
  end

  test "new/2 snapshots profile, formatters and lookups" do
    runtime = Runtime.new(AshRpc.Test.Profile)
    manifest = AshRpc.Test.ManifestBuilder.manifest()

    assert runtime.profile == AshRpc.Test.Profile
    assert runtime.manifest == manifest
    assert runtime.mapping_source == AshRpc.Test.MappingSource
    assert runtime.input_formatter == :camel_case
    assert runtime.output_formatter == :camel_case
    assert runtime.resource_lookup == AshRpc.Manifest.resource_lookup(manifest)
    assert runtime.entrypoints["list_posts"].action == :read
  end

  test "manifest: option overrides the profile's manifest" do
    other = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)
    assert Runtime.new(AshRpc.Test.Profile, manifest: other).output_formatter == :pascal_case
  end

  test "an undecorated profile manifest raises ArgumentError naming the profile" do
    assert_raise ArgumentError, ~r/AshRpc.RuntimeTest.Undecorated/, fn ->
      Runtime.new(Undecorated)
    end
  end

  test "from_manifest/2 works without a profile (typed controllers/channels)" do
    runtime = Runtime.from_manifest(AshRpc.Test.ManifestBuilder.manifest())
    assert runtime.profile == nil
    assert runtime.output_formatter == :camel_case
  end
end
