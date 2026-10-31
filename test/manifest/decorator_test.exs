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
  defp action(m, resource, name), do: AshRpc.Manifest.action_lookup(m)[{resource, name}]
  defp input_type(action, name), do: Enum.find(action.inputs, &(&1.name == name)).type

  test "manifest-level custom.ash_rpc", %{manifest: m} do
    rpc = AshRpc.Manifest.ash_rpc(m)
    assert rpc.mapping_source == AshRpc.Test.MappingSource
    refute Map.has_key?(rpc, :input_formatter)
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

  test "unexposed domain resources used as struct inputs get formatter names", %{manifest: m} do
    voucher = resource(m, AshRpc.Test.Voucher)
    refute Custom.exposed?(voucher)

    assert Custom.field_names(voucher) == %{
             id: "id",
             voucher_code: "voucherCode",
             post_id: "postId"
           }

    assert Custom.field_name_overrides(voucher) == %{}
    refute Map.has_key?(resource(m, AshRpc.Test.Secret).custom, :ash_rpc)
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

  describe "resource reverse maps" do
    test "client_field_names is the reverse of field_names, overrides included", %{manifest: m} do
      rpc = resource(m, AshRpc.Test.Author) |> Custom.ash_rpc()

      assert rpc.client_field_names["isActive"] == :is_active?
      assert rpc.client_field_names["name"] == :name
      assert rpc.client_field_names == Map.new(rpc.field_names, fn {k, v} -> {v, k} end)
    end

    test "calculation arguments are named with the output formatter", %{manifest: m} do
      rpc = resource(m, AshRpc.Test.Post) |> Custom.ash_rpc()

      assert rpc.calculation_argument_names[:excerpt] ==
               %{"length" => :length, "omissionText" => :omission_text}

      refute Map.has_key?(rpc.calculation_argument_names, :title_length)
    end
  end

  describe "type names" do
    test "a named type with overrides gets forward and reverse names", %{manifest: m} do
      type = Manifest.get_type(AshRpc.Manifest.type_lookup(m), AshRpc.Test.PostStats)
      rpc = Custom.ash_rpc(type)

      assert rpc.field_names[:word_count_1] == "wordCount1"
      assert rpc.client_field_names["wordCount1"] == :word_count_1
      assert rpc.field_name_overrides[:word_count_1] == "wordCount1"
    end

    test "inline union members and their typed-map fields are decorated", %{manifest: m} do
      union =
        m
        |> action(AshRpc.Test.Widget, :create)
        |> input_type(:attachments)
        |> Map.fetch!(:item_type)

      assert Custom.ash_rpc(union).client_member_names["file"] == :file
      file = Enum.find(union.members, &(&1.name == :file)).type
      assert Custom.ash_rpc(file).client_field_names["mimeType"] == :mime_type
      refute Map.has_key?(Custom.ash_rpc(file), :field_name_overrides)
    end

    test "inline return and resource field types are decorated", %{manifest: m} do
      returns = action(m, AshRpc.Test.Catalog, :assign).returns
      assert Custom.ash_rpc(returns).client_field_names["assigneeId"] == :assignee_id

      coords = m |> action(AshRpc.Test.Place, :create) |> input_type(:coordinates)
      assert Custom.ash_rpc(coords).client_field_names["latitude"] == :latitude
    end

    test "decorate_type/3 decorates a type built outside the manifest" do
      type =
        Ash.Info.Manifest.Generator.TypeResolver.resolve(Ash.Type.Map,
          fields: [mime_type: [type: :string], alt_text: [type: :string]]
        )

      decorated = Decorator.decorate_type(type, :camel_case, AshRpc.Test.MappingSource)

      assert Custom.ash_rpc(decorated).client_field_names ==
               %{"mimeType" => :mime_type, "altText" => :alt_text}
    end
  end

  describe "vocabulary" do
    test "fixed request names are formatted per scope", %{manifest: m} do
      vocab = AshRpc.Manifest.ash_rpc(m).vocabulary

      assert vocab.params["getBy"] == :get_by
      assert vocab.params["metadataFields"] == :metadata_fields
      assert vocab.params["input"] == :input
      assert vocab.params["identity"] == :identity
      assert vocab.page["after"] == :after
      assert vocab.query_opts["args"] == :args
      assert vocab.filter_ops["greaterThan"] == :greater_than
      assert vocab.filter_ops["isNil"] == :is_nil
      assert vocab.filter_ops["gte"] == :gte
      assert vocab.filter_ops["stringLength"] == :string_length
      assert vocab.filter_ops["and"] == :and
      assert vocab.filter_ops["input"] == :input
    end

    defmodule OffsetAsLimit do
      def format(:offset), do: "limit"
      def format(name), do: AshRpc.FieldFormatter.format_field_name(name, :camel_case)
    end

    test "two vocabulary names mapping to one string raise NameCollisionError" do
      assert_raise AshRpc.Manifest.NameCollisionError, ~r/vocabulary :page/, fn ->
        AshRpc.Test.ManifestBuilder.build(output_formatter: {OffsetAsLimit, :format})
      end
    end

    test "wire entrypoints carry a reverse map of their exposed metadata fields", %{manifest: m} do
      e = AshRpc.Manifest.entrypoint_lookup(m)["read_posts_with_metadata"]

      assert e.client_metadata_field_names == %{
               "totalScore" => :total_score,
               "meta1" => :meta_1,
               "isCached" => :is_cached?,
               "breakdown" => :breakdown,
               "extra" => :extra
             }
    end
  end

  defmodule NoInputFormatterSource do
    @moduledoc false
    @behaviour AshRpc.MappingSource
    @impl true
    defdelegate output_formatter, to: AshRpc.Test.MappingSource
    @impl true
    defdelegate exposed_resource?(resource), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate field_names(resource), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate argument_names(resource, action), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate type_field_names(type), to: AshRpc.Test.MappingSource
    @impl true
    defdelegate entrypoint(entrypoint), to: AshRpc.Test.MappingSource
  end

  test "a mapping source without input_formatter/0 decorates cleanly" do
    manifest =
      AshRpc.Test.ManifestBuilder.generate!([
        %{
          resource: AshRpc.Test.Post,
          action: :read,
          config: %{ash_rpc_test: %{name: "list_posts", opts: []}}
        }
      ])

    assert %{output_formatter: :camel_case} =
             manifest |> Decorator.decorate(NoInputFormatterSource) |> AshRpc.Manifest.ash_rpc()
  end
end
