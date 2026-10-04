# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.DecoratorTest do
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias AshRpc.Manifest.{Custom, Decorator}

  setup_all do
    %{manifest: AshRpc.Test.ManifestBuilder.manifest()}
  end

  defp resource(m, mod), do: AshRpc.Manifest.resource_lookup(m)[mod]

  test "manifest-level custom.ash_rpc", %{manifest: m} do
    rpc = AshRpc.Manifest.ash_rpc(m)
    assert rpc.mapping_source == AshRpc.Test.MappingSource
    assert rpc.input_formatter == :camel_case
    assert rpc.output_formatter == :camel_case

    assert %AshRpc.Entrypoint{resource: AshRpc.Test.Post, action: :read} =
             rpc.entrypoints["list_posts"]

    assert AshRpc.Manifest.entrypoint_lookup(m) == rpc.entrypoints
  end

  test "exposed resources carry precomputed names; overrides win", %{manifest: m} do
    author = resource(m, AshRpc.Test.Author)
    assert Custom.field_names(author)[:is_active?] == "isActive"
    assert Custom.field_names(author)[:name] == "name"
    assert Custom.field_names(author)[:posts] == "posts"
    assert Custom.original_field_name(author, "isActive") == :is_active?
    assert Custom.authorize_bulk_strategy(author) in [:error, :filter]
  end

  test "argument overrides are scoped per action", %{manifest: m} do
    post = resource(m, AshRpc.Test.Post)
    assert Custom.argument_name_overrides(post, :word_count) == %{text: "body"}
    assert Custom.original_argument_name(post, :word_count, "body") == :text
  end

  test "unexposed resources are left undecorated (strict exposure)", %{manifest: m} do
    refute Custom.exposed?(resource(m, AshRpc.Test.Secret))
  end

  test "embedded resources are decorated and in the resource lookup", %{manifest: m} do
    assert Custom.exposed?(resource(m, AshRpc.Test.PostSettings))
  end

  test "mapped types carry overrides", %{manifest: m} do
    type = AshRpc.Manifest.type_lookup(m)[AshRpc.Test.PostStats]

    assert Custom.type_field_name_overrides(type) == %{
             word_count_1: "wordCount1",
             is_featured?: "isFeatured"
           }
  end

  test "entrypoint actions carry expected input keys, field types and return classification",
       %{manifest: m} do
    action = AshRpc.Manifest.action_lookup(m)[{AshRpc.Test.Post, :word_count}]
    assert Custom.action_expected_input_keys(action) == %{"body" => :text}
    assert is_map(Custom.action_input_field_types(action))
    refute is_nil(Custom.action_return_classification(action))
  end

  test "custom {Mod, fun} output formatter" do
    m = AshRpc.Test.ManifestBuilder.build(output_formatter: {__MODULE__, :shout})

    author = resource(m, AshRpc.Test.Author)
    assert Custom.field_names(author)[:name] == "NAME"
    assert Custom.field_names(author)[:is_active?] == "isActive"
  end

  test "a formatter returning a non-string raises naming formatter and field" do
    assert_raise ArgumentError, ~r/#{inspect(__MODULE__)}.*:bad.*field :\w+/s, fn ->
      AshRpc.Test.ManifestBuilder.build(output_formatter: {__MODULE__, :bad})
    end
  end

  test "two fields formatting to the same client name raise" do
    assert_raise AshRpc.Manifest.NameCollisionError,
                 ~r/AshRpc.Test.Author.*:id and :name/s,
                 fn ->
                   AshRpc.Test.ManifestBuilder.build(output_formatter: {__MODULE__, :collide})
                 end
  end

  def shout(field), do: field |> to_string() |> String.upcase()
  def bad(_field), do: :not_a_string
  def collide(field) when field in [:id, :name], do: "same"
  def collide(field), do: to_string(field)

  test "decorate/3 is idempotent", %{manifest: m} do
    assert Decorator.decorate(m, AshRpc.Test.MappingSource) == m
  end

  test "lookups are embedded and merge embedded resources", %{manifest: m} do
    lookups = m.custom.ash_rpc.lookups
    assert %Manifest.Resource{} = lookups.resource[AshRpc.Test.PostSettings]
    assert Map.has_key?(lookups.action, {AshRpc.Test.Post, :read})
  end
end
