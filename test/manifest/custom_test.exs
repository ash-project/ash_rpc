# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.CustomTest do
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias AshRpc.Manifest.Custom

  setup_all do
    %{manifest: AshRpc.Test.ManifestBuilder.manifest()}
  end

  defp resource(m, mod), do: AshRpc.Manifest.resource_lookup(m)[mod]

  test "type_field_names/1 is the forward map of a decorated type", %{manifest: m} do
    type = AshRpc.Manifest.type_lookup(m)[AshRpc.Test.PostStats]
    names = Custom.type_field_names(type)
    assert names[:word_count_1] == "wordCount1"
    assert names[:is_featured?] == "isFeatured"
    assert Map.new(names, fn {k, v} -> {v, k} end) == Custom.type_client_field_names(type)
  end

  test "type_member_names/1 inverts client_member_names", %{manifest: m} do
    union = resource(m, AshRpc.Test.Intake).fields[:status].type
    assert Custom.type_member_names(union) == %{active: "active", inactive: "inactive"}
  end

  test "entrypoint_metadata_field_names/1 inverts client_metadata_field_names", %{manifest: m} do
    e = AshRpc.Manifest.entrypoint_lookup(m)["read_posts_with_metadata"]

    assert Custom.entrypoint_metadata_field_names(e) ==
             Map.new(e.client_metadata_field_names, fn {c, f} -> {f, c} end)

    assert Custom.entrypoint_metadata_field_names(e)[:is_cached?] == "isCached"
  end

  test "undecorated nodes read as empty" do
    assert Custom.type_field_names(%Manifest.Type{}) == %{}
    assert Custom.type_member_names(%Manifest.Type{kind: :union}) == %{}
    assert Custom.entrypoint_metadata_field_names(%AshRpc.Entrypoint{}) == %{}
    assert Custom.type_field_names(nil) == %{}
    assert Custom.type_member_names(nil) == %{}
    assert Custom.entrypoint_metadata_field_names(nil) == %{}
  end

  test "readers follow the formatter, overrides used as written" do
    m = AshRpc.Test.ManifestBuilder.build(output_formatter: :snake_case)
    type = AshRpc.Manifest.type_lookup(m)[AshRpc.Test.PostStats]
    assert Custom.type_field_names(type)[:is_featured?] == "isFeatured"

    union = resource(m, AshRpc.Test.Intake).fields[:status].type
    assert Custom.type_member_names(union) == %{active: "active", inactive: "inactive"}
  end
end
