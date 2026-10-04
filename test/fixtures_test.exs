# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FixturesTest do
  use ExUnit.Case, async: true

  test "fixture resources persist through ETS" do
    author =
      AshRpc.Test.Author
      |> Ash.Changeset.for_create(:create, %{name: "Ada"})
      |> Ash.create!()

    assert author.is_active? == true
    assert [%{name: "Ada"}] = Ash.read!(AshRpc.Test.Author)
  end

  test "the manifest generator sees the :ash_rpc fixture domain and keeps entrypoint config" do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: :ash_rpc,
        action_entrypoints: [
          %{
            resource: AshRpc.Test.Post,
            action: :read,
            config: %{ash_rpc_test: %{name: "list_posts"}}
          }
        ]
      )

    assert [%Ash.Info.Manifest.Entrypoint{resource: AshRpc.Test.Post, config: config}] =
             manifest.entrypoints

    assert config == %{ash_rpc_test: %{name: "list_posts"}}
    assert Enum.any?(manifest.resources, &(&1.module == AshRpc.Test.Secret))
    assert Enum.any?(manifest.types, &(&1.module == AshRpc.Test.PostSettings))
  end
end
