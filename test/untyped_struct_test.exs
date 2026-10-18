# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.UntypedStructTest do
  # A struct with no field types (a plain `defstruct`, or `:struct` without
  # `fields`) can't be selected, named or filtered, so every field it carries
  # would reach the client. Decoration rejects it wherever the wire can reach.
  use ExUnit.Case, async: true

  alias AshRpc.Manifest.{Decorator, UntypedStructError}
  alias AshRpc.ResultProcessor
  alias AshRpc.Test.{Catalog, ManifestBuilder, MappingSource}

  defp entrypoint(action) do
    %{resource: Catalog, action: action, config: %{ash_rpc_test: %{name: "#{action}", opts: []}}}
  end

  defp decorate(actions) do
    actions
    |> Enum.map(&entrypoint/1)
    |> ManifestBuilder.generate!()
    |> Decorator.decorate(MappingSource)
  end

  # `{resource, action, entry_opts}` rows; entry opts set `%AshRpc.Entrypoint{}` fields.
  defp decorate_rows(rows) do
    rows
    |> Enum.map(fn {resource, action, opts} ->
      %{
        resource: resource,
        action: action,
        config: %{ash_rpc_test: %{name: "#{action}", opts: opts}}
      }
    end)
    |> ManifestBuilder.generate!()
    |> Decorator.decorate(MappingSource)
  end

  describe "decoration rejects untyped structs" do
    test "a return of a plain struct module" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_result])
        end

      assert error.message =~ "AshRpc.Test.PlainSession"
      assert error.message =~ "plain_struct_result"

      assert error.message =~
               ~s(Entrypoint "plain_struct_result" \(AshRpc.Test.Catalog, action :plain_struct_result\) ) <>
                 "returns an untyped struct, AshRpc.Test.PlainSession, at returns.\n"

      assert error.path == ["returns"]
      assert error.struct_module == AshRpc.Test.PlainSession

      assert error.entrypoint == %{
               name: "plain_struct_result",
               resource: Catalog,
               action: :plain_struct_result
             }
    end

    test "a :struct return without fields or instance_of" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn -> decorate([:bare_struct_result]) end

      assert error.message =~
               "returns an untyped struct, `:struct` without constraints, at returns."

      assert error.struct_module == nil
    end

    test "a plain struct instance_of with an empty field list" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_empty_fields])
        end

      assert error.message =~
               "returns an untyped struct, AshRpc.Test.PlainSession, at returns.\n"

      assert error.path == ["returns"]
      assert error.struct_module == AshRpc.Test.PlainSession
    end

    test "a :struct with an empty field list and no instance_of" do
      # It returns a `%PlainSession{}`: decorated, every field would reach the client.
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:empty_struct_fields])
        end

      assert error.message =~
               ~s(Entrypoint "empty_struct_fields" \(AshRpc.Test.Catalog, action :empty_struct_fields\) ) <>
                 "returns an untyped struct, `:struct` with no fields, at returns.\n"

      assert error.path == ["returns"]
      assert error.struct_module == nil
    end

    test "an array of plain structs" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn -> decorate([:plain_struct_list]) end

      assert error.message =~ "at returns → []."
      assert error.path == ["returns", []]
    end

    test "a plain struct nested in a typed map" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_in_typed_map])
        end

      assert error.message =~ "session"
      assert error.message =~ "at returns → session."
    end

    test "an argument of a plain struct" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_argument])
        end

      assert error.message =~
               "accepts an untyped struct, AshRpc.Test.PlainSession, at argument :session."

      assert error.path == ["argument :session"]
    end

    test "a union member that is a plain struct" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_in_union])
        end

      assert error.message =~ "at returns → session."
    end

    test "a named NewType over a plain struct, through :type_ref" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn -> decorate([:plain_struct_named]) end

      assert error.message =~
               "returns an untyped struct, AshRpc.Test.PlainSession " <>
                 "(through the NewType AshRpc.Test.PlainSessionType), at returns."
    end

    test "a public attribute of an embedded resource reached" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_in_embedded])
        end

      assert error.message =~ "AshRpc.Test.PlainSession, at returns → session."
    end

    test "`:struct` with `instance_of` a TypedStruct" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:typed_struct_instance_of])
        end

      assert error.message =~ "an untyped struct, AshRpc.Test.TaskStats, at returns."
      assert error.message =~ "AshRpc.Test.TaskStats is an Ash type: use it as the type"
    end

    test "a generic action's argument named like an attribute is an argument" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate([:plain_struct_id_argument])
        end

      assert error.message =~
               "accepts an untyped struct, AshRpc.Test.PlainSession, at argument :id."
    end

    test "the records of a read" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate_rows([{AshRpc.Test.SessionLog, :read, []}])
        end

      assert error.message =~
               ~s(Entrypoint "read" \(AshRpc.Test.SessionLog, action :read\) returns an untyped ) <>
                 "struct, AshRpc.Test.PlainSession, at AshRpc.Test.SessionLog records → session."

      assert error.path == ["AshRpc.Test.SessionLog records", :session]
    end

    test "an attribute reached through a relationship to an exposed resource" do
      # Relationships are followed through the decorated resources: the
      # undecorated ones carry no `exposed` flag.
      error =
        assert_raise UntypedStructError, fn ->
          decorate_rows([{AshRpc.Test.SessionOwner, :read, []}])
        end

      assert error.path == ["AshRpc.Test.SessionOwner records", :log, :session]
      assert error.message =~ "at AshRpc.Test.SessionOwner records → log → session."
    end

    test "an accepted attribute, reported before the records" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate_rows([{AshRpc.Test.SessionLog, :create, []}])
        end

      assert error.message =~
               "accepts an untyped struct, AshRpc.Test.PlainSession, at attribute :session."
    end

    test "exposed metadata" do
      error =
        assert_raise AshRpc.Manifest.UntypedStructError, fn ->
          decorate_rows([
            {Catalog, :read_with_session_meta, [exposed_metadata_fields: [:session]]}
          ])
        end

      assert error.message =~
               "returns an untyped struct, AshRpc.Test.PlainSession, at metadata :session."
    end

    test "a generic action doesn't return its resource's records" do
      assert %Ash.Info.Manifest{} = decorate_rows([{AshRpc.Test.SessionLog, :ping, []}])
    end

    test "metadata the entrypoint doesn't expose" do
      assert %Ash.Info.Manifest{} =
               decorate_rows([{Catalog, :read_with_session_meta, [exposed_metadata_fields: []]}])
    end

    test "only wire entrypoints are checked" do
      # The test mapping source returns `nil` for an entrypoint without
      # `ash_rpc_test` config, so it is not a wire entrypoint.
      assert %Ash.Info.Manifest{} =
               [%{resource: Catalog, action: :plain_struct_result, config: %{}}]
               |> ManifestBuilder.generate!()
               |> Decorator.decorate(MappingSource)
    end
  end

  describe "check_untyped_structs!/3" do
    # Off-wire entrypoints (no `ash_rpc_test` config, so the mapping source
    # returns nil) decorate; an extension checks them itself.
    setup do
      manifest =
        [:plain_struct_argument, :task_stats, :read_with_session_meta]
        |> Enum.map(&%{resource: Catalog, action: &1, config: %{}})
        |> ManifestBuilder.generate!()
        |> Decorator.decorate(MappingSource)

      lookups = %{
        resource_lookup: AshRpc.Manifest.resource_lookup(manifest),
        type_lookup: AshRpc.Manifest.type_lookup(manifest)
      }

      %{manifest: manifest, lookups: lookups}
    end

    defp manifest_entrypoint(manifest, action),
      do: Enum.find(manifest.entrypoints, &(&1.action.name == action))

    defp wire(action, opts \\ []),
      do: struct!(AshRpc.Entrypoint, [name: "probe", resource: Catalog, action: action] ++ opts)

    test "raises for an off-wire entrypoint that reaches an untyped struct", ctx do
      entrypoint = manifest_entrypoint(ctx.manifest, :plain_struct_argument)

      error =
        assert_raise UntypedStructError, fn ->
          Decorator.check_untyped_structs!(entrypoint, wire(:plain_struct_argument), ctx.lookups)
        end

      assert error.message =~
               ~s(Entrypoint "probe" \(AshRpc.Test.Catalog, action :plain_struct_argument\) ) <>
                 "accepts an untyped struct, AshRpc.Test.PlainSession, at argument :session."

      assert error.entrypoint == %{
               name: "probe",
               resource: Catalog,
               action: :plain_struct_argument
             }
    end

    test "checks the metadata the given entrypoint exposes", ctx do
      entrypoint = manifest_entrypoint(ctx.manifest, :read_with_session_meta)

      assert :ok =
               Decorator.check_untyped_structs!(
                 entrypoint,
                 wire(:read_with_session_meta),
                 ctx.lookups
               )

      error =
        assert_raise UntypedStructError, fn ->
          Decorator.check_untyped_structs!(
            entrypoint,
            wire(:read_with_session_meta, exposed_metadata_fields: [:session]),
            ctx.lookups
          )
        end

      assert error.message =~
               "returns an untyped struct, AshRpc.Test.PlainSession, at metadata :session."
    end

    test "returns :ok for a typed entrypoint", ctx do
      entrypoint = manifest_entrypoint(ctx.manifest, :task_stats)
      assert :ok = Decorator.check_untyped_structs!(entrypoint, wire(:task_stats), ctx.lookups)
    end
  end

  describe "UntypedStructError" do
    alias Ash.Info.Manifest.Type

    test "names the module, entrypoint, path and alternatives" do
      type = %Type{kind: :struct, module: Ash.Type.Struct, instance_of: AshRpc.Test.PlainSession}

      error =
        UntypedStructError.exception(
          type: type,
          path: ["returns", :session, []],
          verb: "returns",
          entrypoint: %{name: "get_session", resource: Catalog, action: :get_session}
        )

      assert error.struct_module == AshRpc.Test.PlainSession
      assert error.path == ["returns", :session, []]
      assert error.entrypoint == %{name: "get_session", resource: Catalog, action: :get_session}

      assert error.message =~
               ~s(Entrypoint "get_session" \(AshRpc.Test.Catalog, action :get_session\) ) <>
                 "returns an untyped struct, AshRpc.Test.PlainSession, at returns → session → [].\n"

      for alt <- [
            "Ash.TypedStruct",
            "a NewType over :struct with `fields` constraints",
            "`instance_of` an Ash resource",
            "`:map` with no constraints"
          ] do
        assert error.message =~ alt
      end

      refute error.message =~ "is an Ash type"
    end

    test "details/2 describes a bare :struct, a NewType and an Ash-type instance_of" do
      assert UntypedStructError.details(%Type{kind: :struct, module: Ash.Type.Struct}, ["returns"]) =~
               "an untyped struct, `:struct` without constraints, at returns.\n"

      assert UntypedStructError.details(%Type{kind: :struct}, ["returns"]) =~
               "an untyped struct, `:struct` without constraints, at returns.\n"

      assert UntypedStructError.details(
               %Type{
                 kind: :struct,
                 module: AshRpc.Test.PlainSessionType,
                 instance_of: AshRpc.Test.PlainSession
               },
               ["returns"]
             ) =~
               "an untyped struct, AshRpc.Test.PlainSession (through the NewType " <>
                 "AshRpc.Test.PlainSessionType), at returns.\n"

      details =
        UntypedStructError.details(
          %Type{kind: :struct, module: Ash.Type.Struct, instance_of: AshRpc.Test.TaskStats},
          ["returns"]
        )

      assert details =~
               "AshRpc.Test.TaskStats is an Ash type: use it as the type instead of " <>
                 "`:struct` with `instance_of`"
    end

    test "details/2 formats path segments" do
      assert UntypedStructError.details(%Type{kind: :struct}, [
               "argument :session",
               :items,
               [],
               :token
             ]) =~ "at argument :session → items → [] → token.\n"
    end
  end

  describe "typed and explicitly untyped shapes stay allowed" do
    test "a resource instance_of, a TypedStruct, a field-bearing struct and an unconstrained map" do
      assert %Ash.Info.Manifest{} =
               decorate([:search_posts, :task_stats, :struct_summary, :raw_rows])
    end

    test "an empty TypedStruct" do
      manifest = decorate([:empty_typed_struct])
      assert Map.has_key?(manifest.custom.ash_rpc.entrypoints, "empty_typed_struct")
    end

    test "a recursive named type terminates" do
      assert %Ash.Info.Manifest{} = decorate([:tree_result])
    end
  end

  describe "untyped data is sent wholesale" do
    # An unconstrained :map or :term value is the action's value, unchanged:
    # Jason encodes it or the encode fails.
    @profile AshRpc.Test.Profile

    defp run(name), do: AshRpc.run_action(@profile, %AshRpc.Context{}, %{"action" => name})

    test "an unconstrained map return, structs and private fields included" do
      assert %{"success" => true, "data" => data} = response = run("catalog_untyped_records_map")
      assert data == Catalog.untyped_records()
      assert %AshRpc.Test.Account{secret: "s3cr3t"} = data.account
      assert_raise Protocol.UndefinedError, fn -> Jason.encode_to_iodata!(response) end
    end

    test "a :term return and a :term list" do
      assert %{"success" => true, "data" => data} = run("catalog_untyped_records_term")
      assert data == Catalog.untyped_records()

      assert %{"success" => true, "data" => list} = run("catalog_untyped_records_list")

      assert list == [
               Catalog.untyped_account("1"),
               Catalog.untyped_account("2"),
               %AshRpc.Test.TaskStats{total_count: 2}
             ]
    end

    test "values Jason can encode are left to Jason" do
      assert %{"success" => true, "data" => data} =
               response = run("catalog_untyped_value_structs")

      assert data == %{
               at: ~U[2026-01-01 00:00:00Z],
               amount: Decimal.new("1.5"),
               status: :active,
               choice: %Ash.Union{type: :note, value: "n"}
             }

      assert response |> Jason.encode!() |> Jason.decode!() |> Map.fetch!("data") == %{
               "at" => "2026-01-01T00:00:00Z",
               "amount" => "1.5",
               "status" => "active",
               "choice" => "n"
             }
    end

    test "a ForbiddenField inside untyped data fails the encode without its value" do
      assert %{"success" => true, "data" => %{title: %Ash.ForbiddenField{}}} =
               response = run("catalog_untyped_forbidden_field")

      error = assert_raise Protocol.UndefinedError, fn -> Jason.encode_to_iodata!(response) end
      assert Exception.message(error) =~ "Ash.ForbiddenField"
      refute Exception.message(error) =~ "s3cr3t"
    end

    test "process_result/2 passes an error through, not as the untyped value" do
      rt = AshRpc.Runtime.new(@profile)
      action = AshRpc.Introspection.get_action!(rt, Catalog, :untyped_records_map)
      request = %AshRpc.Request{action: action, resource: Catalog, runtime: rt}

      assert AshRpc.Pipeline.process_result({:error, :boom}, request) == {:error, :boom}
    end
  end

  describe "typed paths still normalize" do
    test "a typed resource selected whole, nested embedded structs included" do
      rt = AshRpc.Runtime.new(AshRpc.Test.Profile)

      meta = %AshRpc.Test.ProjectMeta{
        category: "work",
        detail: %AshRpc.Test.ProjectMetaDetail{note: "n", level: 1}
      }

      result = ResultProcessor.process(meta, [], AshRpc.Test.ProjectMeta, rt)
      assert %{category: "work", detail: %{note: "n", level: 1}} = result
      refute is_struct(result)
      refute is_struct(result.detail)
    end

    test "a typed resource selected whole normalizes its untyped attributes" do
      rt = AshRpc.Runtime.new(AshRpc.Test.Profile)
      post = %AshRpc.Test.Post{data: %{"at" => ~U[2026-01-01 00:00:00Z], "k" => :draft}}

      result = ResultProcessor.process(post, [], AshRpc.Test.Post, rt)
      assert result.data == %{"at" => "2026-01-01T00:00:00Z", "k" => "draft"}
    end
  end
end
