# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldNameTranslationTest do
  use ExUnit.Case, async: true

  # Post's client names collide with names elsewhere: "name" with Author's own
  # `name` attribute, "total" with a field of the `totals` action's typed return.
  # Each selection must be translated with the names of the type it belongs to.
  defmodule CollidingMappingSource do
    @moduledoc false
    @behaviour AshRpc.MappingSource

    @impl true
    defdelegate input_formatter, to: AshRpc.Test.MappingSource
    @impl true
    defdelegate output_formatter, to: AshRpc.Test.MappingSource
    @impl true
    defdelegate exposed_resource?(resource), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate argument_names(resource, action), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate type_field_names(type), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate entrypoint(entrypoint), to: AshRpc.Test.MappingSource

    @impl true
    def field_names(AshRpc.Test.Post), do: %{view_count: "name", title: "total"}
    def field_names(resource), do: AshRpc.Test.MappingSource.field_names(resource)
  end

  defp manifest do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(
        otp_app: :ash_rpc,
        action_entrypoints: [
          %{
            resource: AshRpc.Test.Post,
            action: :read,
            config: %{ash_rpc_test: %{name: "list_posts"}}
          },
          %{
            resource: AshRpc.Test.Post,
            action: :totals,
            config: %{ash_rpc_test: %{name: "totals"}}
          }
        ]
      )

    AshRpc.Manifest.Decorator.decorate(manifest, CollidingMappingSource, [])
  end

  test "nested relationship fields are translated with the related resource's names" do
    assert %{"success" => true, "data" => []} =
             AshRpc.run_action(
               AshRpc.Test.Profile,
               %AshRpc.Context{},
               %{"action" => "list_posts", "fields" => ["id", %{"author" => ["name"]}]},
               manifest: manifest()
             )
  end

  test "a generic action's typed return is not translated with the resource's names" do
    assert %{"success" => true, "data" => %{"total" => 2}} =
             AshRpc.run_action(
               AshRpc.Test.Profile,
               %AshRpc.Context{},
               %{"action" => "totals", "fields" => ["total"]},
               manifest: manifest()
             )
  end
end
