# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ValidationTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile
  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)
  defp validate(params), do: AshRpc.validate_action(@profile, ctx(), params)

  test "create: a missing required attribute is a native 'required' error" do
    assert %{"success" => false, "errors" => errors} =
             validate(%{"action" => "create_post", "input" => %{}})

    assert Enum.any?(errors, &(&1["type"] == "required" and &1["fields"] == ["title"]))
  end

  test "create: nothing is persisted" do
    assert %{"success" => true} =
             validate(%{"action" => "create_post", "input" => %{"title" => "x"}})

    assert %{"data" => []} = run(%{"action" => "list_posts", "fields" => ["id"]})
  end

  test "read: valid input succeeds" do
    assert %{"success" => true} = validate(%{"action" => "list_posts"})
  end

  test "generic action: missing argument" do
    assert %{"success" => false, "errors" => [error | _]} =
             validate(%{"action" => "word_count", "input" => %{}})

    assert error["type"] in ["required", "invalid_argument"]
  end

  test "update: unknown identity is not_found" do
    assert %{"success" => false, "errors" => [%{"type" => "not_found"}]} =
             validate(%{
               "action" => "update_post",
               "identity" => Ash.UUID.generate(),
               "input" => %{"title" => "y"}
             })
  end

  test "update/destroy: an existing record validates and stays unchanged" do
    %{"data" => %{"id" => id}} =
      run(%{"action" => "create_post", "input" => %{"title" => "a"}, "fields" => ["id"]})

    assert %{"success" => true} =
             validate(%{
               "action" => "update_post",
               "identity" => id,
               "input" => %{"title" => "b"}
             })

    assert %{"success" => true} = validate(%{"action" => "destroy_post", "identity" => id})

    assert %{"data" => [%{"title" => "a"}]} =
             run(%{"action" => "list_posts", "fields" => ["title"]})
  end

  @tag :capture_log
  test "the read_action used for the lookup is the entrypoint's" do
    manifest = AshRpc.Test.ManifestBuilder.manifest()

    entrypoint = %{
      AshRpc.Manifest.entrypoint_lookup(manifest)["update_post"]
      | read_action: :no_such_read
    }

    %{"data" => %{"id" => id}} =
      run(%{"action" => "create_post", "input" => %{"title" => "a"}, "fields" => ["id"]})

    assert %{"success" => false} =
             AshRpc.validate_action(@profile, ctx(), %{"identity" => id, "input" => %{}},
               entrypoint: entrypoint
             )
  end
end
