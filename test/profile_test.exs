# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ProfileTest do
  use ExUnit.Case, async: true

  defmodule Defaults do
    use AshRpc.Profile
    @impl AshRpc.Profile
    def manifest, do: AshRpc.Test.ManifestBuilder.manifest()
  end

  defmodule WithManifestOption do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
  end

  test "use AshRpc.Profile provides spec defaults" do
    assert Defaults.error_handler(nil) == AshRpc.DefaultErrorHandler
    assert Defaults.show_raised_errors?(AshRpc.Test.Domain) == false
    assert Defaults.show_policy_breakdowns?() == false
    assert Defaults.stale_client_hint() == AshRpc.Profile.default_stale_client_hint()
  end

  test "manifest: option resolves through AshRpc.Manifest.fetch!/1" do
    assert WithManifestOption.manifest() == AshRpc.Test.ManifestBuilder.manifest()
  end
end
