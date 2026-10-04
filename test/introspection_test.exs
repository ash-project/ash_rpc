# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.IntrospectionTest do
  use ExUnit.Case, async: true

  alias AshRpc.Introspection

  setup_all do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: :ash_rpc,
        action_entrypoints: [{AshRpc.Test.Post, :read}, {AshRpc.Test.Post, :word_count}]
      )

    %{manifest: manifest, actions: Ash.Info.Manifest.action_lookup(manifest)}
  end

  test "pagination predicates", %{actions: actions} do
    read = actions[{AshRpc.Test.Post, :read}]
    # Ash gives default read actions optional pagination.
    assert Introspection.action_supports_pagination?(read)
    refute Introspection.action_requires_pagination?(read)
  end

  test "return classification of a primitive generic action", %{manifest: m, actions: actions} do
    action = actions[{AshRpc.Test.Post, :word_count}]

    assert Introspection.compute_return_classification(action, Ash.Info.Manifest.type_lookup(m)) ==
             {:error, :not_field_selectable_type}
  end

  test "metadata helpers" do
    refute Introspection.metadata_enabled?([])
    assert Introspection.metadata_enabled?([:x])
  end

  test "ash_resource?/1" do
    assert Introspection.ash_resource?(AshRpc.Test.Post)
    refute Introspection.ash_resource?(String)
    refute Introspection.ash_resource?(nil)
  end
end
