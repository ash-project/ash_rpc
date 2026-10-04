# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.MultitenancyTest do
  use ExUnit.Case, async: true

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}

  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

  defp seed_note(title, tenant),
    do: Ash.create!(AshRpc.Test.Note, %{title: title}, tenant: tenant)

  defp conn_with_tenant(tenant) do
    :post
    |> Plug.Test.conn("/rpc")
    |> Ash.PlugHelpers.set_tenant(tenant)
  end

  defp list_notes(source, extra \\ %{}) do
    params =
      Map.merge(%{"action" => "list_notes", "fields" => ["title"], "sort" => "title"}, extra)

    AshRpc.run_action(@profile, source, params)
  end

  defp parse(ctx, params) do
    AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx, params)
  end

  describe "tenant param on a multitenant resource" do
    test "scopes reads to the tenant" do
      seed_note("one", "w1")
      seed_note("two", "w2")

      assert %{"success" => true, "data" => [%{"title" => "one"}]} =
               list_notes(ctx(), %{"tenant" => "w1"})

      assert %{"success" => true, "data" => [%{"title" => "two"}]} =
               list_notes(ctx(), %{"tenant" => "w2"})
    end

    test "scopes creates to the tenant" do
      assert %{"success" => true, "data" => %{"title" => "n", "workspaceId" => "w1"}} =
               run(%{
                 "action" => "create_note",
                 "tenant" => "w1",
                 "input" => %{"title" => "n"},
                 "fields" => ["title", "workspaceId"]
               })

      assert [%{title: "n"}] = Ash.read!(AshRpc.Test.Note, tenant: "w1")
      assert [] = Ash.read!(AshRpc.Test.Note, tenant: "w2")
    end
  end

  describe "tenant param overrides the transport tenant" do
    test "overrides the context tenant" do
      seed_note("one", "w1")
      seed_note("two", "w2")

      assert %{"success" => true, "data" => [%{"title" => "one"}]} =
               list_notes(%AshRpc.Context{tenant: "w1"})

      assert %{"success" => true, "data" => [%{"title" => "two"}]} =
               list_notes(%AshRpc.Context{tenant: "w1"}, %{"tenant" => "w2"})
    end

    test "overrides the conn tenant" do
      seed_note("one", "w1")
      seed_note("two", "w2")

      assert %{"success" => true, "data" => [%{"title" => "one"}]} =
               list_notes(conn_with_tenant("w1"))

      assert %{"success" => true, "data" => [%{"title" => "two"}]} =
               list_notes(conn_with_tenant("w1"), %{"tenant" => "w2"})
    end
  end

  describe "missing tenant on a multitenant resource" do
    test "a read is tenant_required" do
      seed_note("one", "w1")

      # Ash.Actions.Read validate_multitenancy returns TenantRequired;
      # AshRpc.Error impl maps it to "tenant_required" / "Tenant required".
      assert %{
               "success" => false,
               "errors" => [%{"type" => "tenant_required", "shortMessage" => "Tenant required"}]
             } = list_notes(ctx())
    end

    test "a create is invalid_changes" do
      # Single create runs Ash.Actions.Create handle_multitenancy, which adds the
      # string error "... changesets require a tenant to be specified" (InvalidChanges),
      # not TenantRequired (that one is only raised by reads and bulk actions).
      assert %{"success" => false, "errors" => [%{"type" => "invalid_changes"} = error]} =
               run(%{
                 "action" => "create_note",
                 "input" => %{"title" => "n"},
                 "fields" => ["title"]
               })

      assert error["message"] =~ "require a tenant"
    end
  end

  describe "tenant param on a non-multitenant resource" do
    test "is accepted and the action runs" do
      Ash.create!(AshRpc.Test.Post, %{title: "p"})

      assert %{"success" => true, "data" => [%{"title" => "p"}]} =
               run(%{
                 "action" => "list_posts",
                 "fields" => ["title"],
                 "tenant" => "org_123"
               })
    end

    test "the request tenant is the param, or nil without one" do
      params = %{"action" => "list_posts", "fields" => ["title"]}

      assert {:ok, %AshRpc.Request{tenant: "org_123"}} =
               parse(ctx(), Map.put(params, "tenant", "org_123"))

      assert {:ok, %AshRpc.Request{tenant: nil}} = parse(ctx(), params)
    end
  end

  describe "nested envelope" do
    test "a paged replies envelope stays inside the tenant" do
      note = seed_note("n", "w1")

      for body <- ["r1", "r2", "r3"] do
        assert %{"success" => true} =
                 run(%{
                   "action" => "create_note_reply",
                   "tenant" => "w1",
                   "input" => %{"body" => body, "noteId" => note.id},
                   "fields" => ["id"]
                 })
      end

      # Same note_id, other tenant: must not appear under the w1 note.
      Ash.create!(AshRpc.Test.NoteReply, %{body: "r0-other", note_id: note.id}, tenant: "w2")

      assert %{"success" => true, "data" => [%{"replies" => page}]} =
               run(%{
                 "action" => "list_notes",
                 "tenant" => "w1",
                 "fields" => [
                   %{
                     "replies" => %{
                       "page" => %{"limit" => 2, "offset" => 0, "count" => true},
                       "sort" => "body",
                       "fields" => ["body"]
                     }
                   }
                 ]
               })

      # ResultProcessor.build_page_map/2 sets type: :offset (an atom, not a string);
      # count on a nested ETS offset page is the in-tenant total.
      assert page["type"] == :offset
      assert page["count"] == 3
      assert page["hasMore"] == true
      assert Enum.map(page["results"], & &1["body"]) == ["r1", "r2"]
    end
  end
end

defmodule AshRpc.MultitenancyChannelTest do
  # Not async: starts the named PubSub/Endpoint that the async AshRpc.ChannelTest
  # also starts; sync modules run only after all async modules have finished.
  use ExUnit.Case, async: false
  import Phoenix.ChannelTest

  @endpoint AshRpc.Test.Endpoint

  setup_all do
    start_supervised!({Phoenix.PubSub, name: AshRpc.Test.PubSub})
    start_supervised!(AshRpc.Test.Endpoint)
    # Build the cached fixture manifest up front so the first push isn't slowed
    # past assert_reply's timeout.
    _ = AshRpc.Test.ManifestBuilder.manifest()
    :ok
  end

  setup do
    {:ok, _, socket} =
      AshRpc.Test.Socket
      |> socket("user", %{ash_actor: nil, ash_tenant: "w1"})
      |> subscribe_and_join(AshRpc.Test.RpcChannel, "rpc:tenant")

    %{socket: socket}
  end

  defp create_note(socket, title, extra \\ %{}) do
    params = %{
      "action" => "create_note",
      "input" => %{"title" => title},
      "fields" => ["title", "workspaceId"]
    }

    push(socket, "run", Map.merge(params, extra))
  end

  defp list_notes(socket, extra \\ %{}) do
    push(socket, "run", Map.merge(%{"action" => "list_notes", "fields" => ["title"]}, extra))
  end

  test "a tenant param overrides the socket tenant", %{socket: socket} do
    ref = create_note(socket, "a")
    assert_reply(ref, :ok, %{"success" => true, "data" => %{"workspaceId" => "w1"}})

    ref = create_note(socket, "b", %{"tenant" => "w2"})
    assert_reply(ref, :ok, %{"success" => true, "data" => %{"workspaceId" => "w2"}})

    ref = list_notes(socket, %{"tenant" => "w2"})
    assert_reply(ref, :ok, %{"success" => true, "data" => [%{"title" => "b"}]})

    ref = list_notes(socket)
    assert_reply(ref, :ok, %{"success" => true, "data" => [%{"title" => "a"}]})
  end
end
