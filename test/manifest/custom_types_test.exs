# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.CustomTypesTest do
  # Custom `use Ash.Type` modules with declared fields become named `:map`
  # definitions in `manifest.types`, and every use becomes a `:type_ref`.
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Generator.TypeResolver
  alias AshRpc.Manifest.{Custom, Decorator}

  alias AshRpc.Test.{
    Amount,
    AmountBreakdown,
    Catalog,
    ManifestBuilder,
    MappingSource,
    Palette,
    Project
  }

  defmodule Orphan do
    @moduledoc false
    use Ash.Resource, data_layer: :embedded

    attributes do
      attribute :label, :string, public?: true
    end
  end

  defmodule SpellingSource do
    @moduledoc false
    # The test mapping source, with a `client_name:` on Palette's accent_color
    # and type_field_names/1 overrides for Palette.
    @behaviour AshRpc.MappingSource

    defdelegate output_formatter, to: MappingSource
    defdelegate exposed_resource?(resource), to: MappingSource
    defdelegate field_names(resource), to: MappingSource
    defdelegate argument_names(resource, action), to: MappingSource
    # Overrides for Palette, which a declared type never reads.
    def type_field_names(Palette), do: %{primary: "main", accent_color: "accentTone"}
    def type_field_names(type), do: MappingSource.type_field_names(type)
    defdelegate entrypoint(entrypoint), to: MappingSource

    def custom_type_fields(Palette) do
      Enum.map(MappingSource.custom_type_fields(Palette), fn
        {:accent_color, opts} -> {:accent_color, Keyword.put(opts, :client_name, "accentColour")}
        spec -> spec
      end)
    end

    def custom_type_fields(module), do: MappingSource.custom_type_fields(module)
  end

  defmodule HiddenProjectSource do
    @moduledoc false
    # The test mapping source with Project unexposed: its Palette use stays
    # `:unknown` in the decorated manifest.
    @behaviour AshRpc.MappingSource

    defdelegate output_formatter, to: MappingSource
    def exposed_resource?(Project), do: false
    def exposed_resource?(resource), do: MappingSource.exposed_resource?(resource)
    defdelegate field_names(resource), to: MappingSource
    defdelegate argument_names(resource, action), to: MappingSource
    defdelegate type_field_names(type), to: MappingSource
    defdelegate entrypoint(entrypoint), to: MappingSource
    defdelegate custom_type_fields(module), to: MappingSource
  end

  defmodule RenamingSource do
    @moduledoc false
    # The test mapping source with type_field_names/1 overrides for Palette,
    # whose specs carry no client_name.
    @behaviour AshRpc.MappingSource

    defdelegate output_formatter, to: MappingSource
    defdelegate exposed_resource?(resource), to: MappingSource
    defdelegate field_names(resource), to: MappingSource
    defdelegate argument_names(resource, action), to: MappingSource
    def type_field_names(Palette), do: %{primary: "main"}
    def type_field_names(type), do: MappingSource.type_field_names(type)
    defdelegate entrypoint(entrypoint), to: MappingSource
    defdelegate custom_type_fields(module), to: MappingSource
  end

  setup_all do
    %{manifest: ManifestBuilder.manifest()}
  end

  defp types(m), do: AshRpc.Manifest.type_lookup(m)
  defp action(m, resource, name), do: AshRpc.Manifest.action_lookup(m)[{resource, name}]
  defp field(%Manifest.Type{} = type, name), do: Manifest.Type.find_field(type, name)
  defp entries_for(m, module), do: Enum.filter(m.types, &(&1.module == module))

  # Off-wire Catalog entrypoints: decorated, but not checked for untyped structs.
  defp decorate(actions, opts \\ []) do
    actions
    |> Enum.map(&%{resource: Catalog, action: &1, config: %{}})
    |> ManifestBuilder.generate!()
    |> Decorator.decorate(MappingSource, opts)
  end

  defp project_rows do
    [
      %{
        resource: Project,
        action: :read,
        config: %{ash_rpc_test: %{name: "list_projects", opts: []}}
      },
      %{
        resource: Catalog,
        action: :amount_result,
        config: %{ash_rpc_test: %{name: "catalog_amount_result", opts: []}}
      }
    ]
  end

  test "a declared custom type is a named :map definition", %{manifest: m} do
    definition = types(m)[Palette]

    assert %Manifest.Type{
             kind: :map,
             name: "Palette",
             module: Palette,
             instance_of: nil,
             constraints: []
           } = definition

    assert %{allow_nil?: false, type: %Manifest.Type{kind: :string}} = field(definition, :primary)

    assert %{allow_nil?: false, type: %Manifest.Type{kind: :string}} =
             field(definition, :secondary)

    assert %{allow_nil?: true, type: %Manifest.Type{kind: :string}} =
             field(definition, :accent_color)

    assert Custom.type_field_names(definition) == %{
             primary: "primary",
             secondary: "secondary",
             accent_color: "accentColor"
           }

    assert Custom.custom_type?(definition)
    assert length(entries_for(m, Palette)) == 1
  end

  test "each use becomes a :type_ref with the use's constraints", %{manifest: m} do
    project = AshRpc.Manifest.resource_lookup(m)[Project]

    assert %Manifest.Type{kind: :type_ref, module: Palette, name: "Palette", constraints: []} =
             project.fields[:palette].type

    # Trail isn't declared: it stays a custom type.
    assert %Manifest.Type{kind: :unknown, module: AshRpc.Test.Trail} =
             project.fields[:strict_trail].type
  end

  test "a :type_ref keeps the use's allow_nil?" do
    ref =
      %Manifest.Type{TypeResolver.resolve(Palette, []) | allow_nil?: false}
      |> Decorator.decorate_type(:camel_case, MappingSource)

    assert %Manifest.Type{kind: :type_ref, module: Palette, allow_nil?: false} = ref
  end

  test "composite types get non-null fields from composite_types/1 at default constraints",
       %{manifest: m} do
    definition = types(m)[Amount]
    assert %Manifest.Type{kind: :map, module: Amount} = definition

    for name <- [:currency, :value, :breakdown] do
      assert %{allow_nil?: false} = field(definition, name)
    end

    assert %Manifest.Type{kind: :type_ref, module: AmountBreakdown} =
             field(definition, :breakdown).type

    # Reached only through Amount's fields, so decoration added it.
    assert %Manifest.Type{} = breakdown = types(m)[AmountBreakdown]
    assert Map.has_key?(Custom.type_client_field_names(breakdown), "taxRate")
  end

  test "a generic action returning a declared type classifies as a typed map", %{manifest: m} do
    assert {:ok, :typed_map, fields} =
             Custom.action_return_classification(action(m, Catalog, :amount_result))

    assert Enum.map(fields, & &1.name) == [:currency, :value, :breakdown]
  end

  test "names come from the specs' client_name, else the formatter, never type_field_names" do
    m = ManifestBuilder.build(mapping_source: SpellingSource)
    definition = types(m)[Palette]

    assert Custom.type_field_names(definition) == %{
             primary: "primary",
             secondary: "secondary",
             accent_color: "accentColour"
           }

    assert {%{accent_color: "accentColour"}, _} =
             Custom.type_field_name_overrides_pair(definition)
  end

  test "type_field_names/1 names no declared field, at decoration or at runtime" do
    m = ManifestBuilder.build(mapping_source: RenamingSource)

    assert Custom.type_field_names(types(m)[Palette]).primary == "primary"
    assert Custom.type_field_name_overrides_pair(types(m)[Palette]) == nil

    params = %{
      "action" => "create_project",
      "input" => %{"palette" => %{"primary" => "red", "secondary" => "blue"}},
      "fields" => [%{"palette" => ["primary"]}]
    }

    assert AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params, manifest: m) ==
             %{"success" => true, "data" => %{"palette" => %{"primary" => "red"}}}
  end

  test "client_name collisions raise NameCollisionError" do
    fields = fn
      Palette -> [a: [type: :string, client_name: "x"], b: [type: :string, client_name: "x"]]
      _ -> nil
    end

    assert_raise AshRpc.Manifest.NameCollisionError,
                 ~r/Palette.*:a and :b both map to "x"/s,
                 fn ->
                   project_rows()
                   |> ManifestBuilder.generate!()
                   |> Decorator.decorate(MappingSource, custom_type_fields: fields)
                 end
  end

  test "an empty or malformed spec list raises ArgumentError naming the module" do
    for specs <- [[], [{"a", [type: :string]}], [a: [constraints: []]], [a: :string]] do
      fields = fn
        Palette -> specs
        _ -> nil
      end

      assert_raise ArgumentError, ~r/AshRpc.Test.Palette/, fn ->
        project_rows()
        |> ManifestBuilder.generate!()
        |> Decorator.decorate(MappingSource, custom_type_fields: fields)
      end
    end
  end

  test "a field declared twice raises ArgumentError naming the module and the field" do
    fields = fn
      Palette -> [primary: [type: :string], primary: [type: :integer]]
      _ -> nil
    end

    assert_raise ArgumentError,
                 "custom type AshRpc.Test.Palette declares the field :primary more than once",
                 fn ->
                   [hd(project_rows())]
                   |> ManifestBuilder.generate!()
                   |> Decorator.decorate(MappingSource, custom_type_fields: fields)
                 end
  end

  test "a NewType over a declared composite type replaces its :unknown entry in place" do
    m = decorate([:composite_new_type])
    definition = types(m)[AshRpc.Test.PlainPointNewType]

    assert %Manifest.Type{kind: :map} = definition
    assert Custom.custom_type?(definition)
    assert length(entries_for(m, AshRpc.Test.PlainPointNewType)) == 1
  end

  test "a recursive declared type is one recursive named type" do
    m = decorate([:composite_recursive])
    definition = types(m)[AshRpc.Test.RecursivePoint]

    assert %Manifest.Type{kind: :type_ref, module: AshRpc.Test.RecursivePoint} =
             field(definition, :next).type

    assert length(entries_for(m, AshRpc.Test.RecursivePoint)) == 1
  end

  test "a resource in declared fields that isn't in the manifest raises" do
    fields = fn
      Palette -> [orphan: [type: Orphan]]
      _ -> nil
    end

    assert_raise ArgumentError, ~r/Palette.*orphan.*Orphan.*is not in the manifest/s, fn ->
      project_rows()
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource, custom_type_fields: fields)
    end
  end

  test "custom_type_fields: replaces the callback" do
    fields = fn
      Palette -> [primary: [type: :string]]
      _ -> nil
    end

    # `amount_result` off the wire: undeclared, Amount would be rejected there.
    m =
      [hd(project_rows()), %{resource: Catalog, action: :amount_result, config: %{}}]
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource, custom_type_fields: fields)

    assert Enum.map(types(m)[Palette].fields, & &1.name) == [:primary]
    # The closure declares nothing else.
    assert types(m)[Amount] == nil
    assert %Manifest.Type{kind: :unknown} = action(m, Catalog, :amount_result).returns
  end

  test "extra_types: declares types used only outside the manifest" do
    m =
      [%{resource: AshRpc.Test.Post, action: :read, config: %{}}]
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource, extra_types: [TypeResolver.resolve(Amount, [])])

    assert %Manifest.Type{kind: :map, module: Amount} = types(m)[Amount]
  end

  test "a definition carries the module's default constraints" do
    m =
      [%{resource: AshRpc.Test.Post, action: :read, config: %{}}]
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource,
        extra_types: [TypeResolver.resolve(AshRpc.Test.ConstrainedPoint, [])]
      )

    assert %Manifest.Type{kind: :map, constraints: [plain?: false]} =
             types(m)[AshRpc.Test.ConstrainedPoint]
  end

  test "an undeclared NewType inside declared fields is added with its :unknown definition" do
    fields = fn
      Palette -> [mode: [type: AshRpc.Test.StorageSwitchNewType]]
      _ -> nil
    end

    m =
      [hd(project_rows())]
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource, custom_type_fields: fields)

    assert %Manifest.Type{kind: :type_ref, module: AshRpc.Test.StorageSwitchNewType} =
             field(types(m)[Palette], :mode).type

    assert [%Manifest.Type{kind: :unknown, name: "StorageSwitchNewType"}] =
             entries_for(m, AshRpc.Test.StorageSwitchNewType)
  end

  test "decorate_type/4 rewrites a declared use and decorate_type/3 still works" do
    use_site = TypeResolver.resolve(Palette, [])

    assert %Manifest.Type{kind: :type_ref, module: Palette} =
             Decorator.decorate_type(use_site, :camel_case, MappingSource)

    assert %Manifest.Type{kind: :unknown, module: Palette} =
             Decorator.decorate_type(use_site, :camel_case, MappingSource,
               custom_type_fields: fn _ -> nil end
             )
  end

  test "an existing non-:unknown entry for a declared module raises (backstop)" do
    manifest = ManifestBuilder.generate!(project_rows())

    manifest = %Manifest{
      manifest
      | types: manifest.types ++ [%Manifest.Type{kind: :string, module: Palette, name: "Palette"}]
    }

    assert_raise ArgumentError, ~r/AshRpc.Test.Palette already has a manifest.types entry/, fn ->
      Decorator.decorate(manifest, MappingSource)
    end
  end

  test "redecorate/2 keeps the definition of a type an unexposed resource uses" do
    m =
      [%{resource: Project, action: :read, config: %{}}]
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(HiddenProjectSource)

    assert %Manifest.Type{kind: :unknown, module: Palette} =
             AshRpc.Manifest.resource_lookup(m)[Project].fields[:palette].type

    snake = AshRpc.Manifest.redecorate(m, output_formatter: :snake_case)

    assert [definition] = entries_for(snake, Palette)
    assert Custom.custom_type?(definition)
    assert Custom.type_field_names(definition).accent_color == "accent_color"
  end

  test "redecorate/2 keeps definitions, markers and overrides", %{manifest: m} do
    snake = AshRpc.Manifest.redecorate(m, output_formatter: :snake_case)
    definition = types(snake)[Palette]

    assert Custom.type_field_names(definition).accent_color == "accent_color"
    assert Custom.custom_type?(definition)
    assert length(entries_for(snake, Palette)) == 1

    # Names from a closure survive a redecorate, which has no closure.
    fields = fn
      Palette -> SpellingSource.custom_type_fields(Palette)
      other -> MappingSource.custom_type_fields(other)
    end

    spelled =
      project_rows()
      |> ManifestBuilder.generate!()
      |> Decorator.decorate(MappingSource, custom_type_fields: fields)
      |> AshRpc.Manifest.redecorate(output_formatter: :snake_case)

    assert Custom.type_field_names(types(spelled)[Palette]) == %{
             primary: "primary",
             secondary: "secondary",
             accent_color: "accentColour"
           }

    assert Custom.custom_type?(types(spelled)[Palette])
  end
end
