# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.EntrypointTest do
  use ExUnit.Case, async: true

  test "defaults match the spec contract" do
    e = %AshRpc.Entrypoint{name: "list_posts", resource: AshRpc.Test.Post, action: :read}

    assert e.get? == false
    assert e.get_by == []
    assert e.identities == [:_primary_key]
    assert e.not_found_error? == true
    assert e.enable_filter? == true
    assert e.enable_sort? == true
    assert e.load_restrictions == :none
    assert e.exposed_metadata_fields == []
    assert e.metadata_field_names == %{}
    assert e.preset_fields == nil
    assert e.read_action == nil
  end

  test "the test mapping source implements the behaviour" do
    behaviours = AshRpc.Test.MappingSource.module_info(:attributes)[:behaviour]
    assert AshRpc.MappingSource in behaviours

    assert AshRpc.Test.MappingSource.field_names(AshRpc.Test.Author) == %{
             is_active?: "isActive",
             is_prolific?: "isProlific"
           }
  end
end
