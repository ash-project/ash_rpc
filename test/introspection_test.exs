# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.IntrospectionTest do
  use ExUnit.Case, async: true

  alias AshRpc.Introspection

  setup_all do
    manifest =
      AshRpc.Test.ManifestBuilder.generate!([
        {AshRpc.Test.Post, :read},
        {AshRpc.Test.Post, :word_count},
        {AshRpc.Test.Catalog, :struct_summary},
        {AshRpc.Test.Catalog, :struct_summaries}
      ])

    %{manifest: manifest, actions: Ash.Info.Manifest.action_lookup(manifest)}
  end

  test "pagination predicates", %{actions: actions} do
    read = actions[{AshRpc.Test.Post, :read}]
    # Ash gives default read actions optional pagination.
    assert Introspection.action_supports_pagination?(read)
    refute Introspection.action_requires_pagination?(read)
  end

  test "return classification of a primitive generic action", %{manifest: m, actions: actions} do
    action = actions[{AshRpc.Test.Post, :word_count}]

    assert Introspection.compute_return_classification(action, Ash.Info.Manifest.type_lookup(m)) ==
             {:error, :not_field_selectable_type}
  end

  test "a :struct with fields and no instance_of classifies as a typed map",
       %{manifest: m, actions: actions} do
    lookup = Ash.Info.Manifest.type_lookup(m)

    assert {:ok, :typed_map, fields} =
             Introspection.compute_return_classification(
               actions[{AshRpc.Test.Catalog, :struct_summary}],
               lookup
             )

    assert Enum.map(fields, & &1.name) == [:title, :word_count, :published]

    assert {:ok, :array_of_typed_map, item_fields} =
             Introspection.compute_return_classification(
               actions[{AshRpc.Test.Catalog, :struct_summaries}],
               lookup
             )

    assert Enum.map(item_fields, & &1.name) == [:title, :word_count]
  end

  test "metadata helpers" do
    refute Introspection.metadata_enabled?([])
    assert Introspection.metadata_enabled?([:x])
  end

  test "ash_resource?/1" do
    assert Introspection.ash_resource?(AshRpc.Test.Post)
    refute Introspection.ash_resource?(String)
    refute Introspection.ash_resource?(nil)
  end

  describe "untyped structs" do
    alias Ash.Info.Manifest.{Argument, Field, Relationship, Resource, Type}

    @plain %Type{
      kind: :struct,
      name: "PlainSession",
      module: Ash.Type.Struct,
      instance_of: AshRpc.Test.PlainSession
    }
    @bare %Type{kind: :struct, name: "Struct", module: Ash.Type.Struct}
    @string %Type{kind: :string, name: "String", module: Ash.Type.String}
    @none %{resource_lookup: %{}, type_lookup: %{}}

    defp resource(module, fields, rels \\ %{}, exposed? \\ true),
      do: %Resource{
        module: module,
        fields: fields,
        relationships: rels,
        custom: %{ash_rpc: %{exposed: exposed?}}
      }

    defp attr(name, type), do: %Field{name: name, kind: :attribute, type: type}

    test "untyped_struct?/1" do
      assert Introspection.untyped_struct?(@plain)
      assert Introspection.untyped_struct?(@bare)
      # An empty field list types only an Ash type (an empty TypedStruct): without
      # `instance_of`, or with a plain struct module, a returned struct's fields would leak.
      assert Introspection.untyped_struct?(%Type{@bare | fields: []})
      assert Introspection.untyped_struct?(%Type{@plain | fields: []})

      refute Introspection.untyped_struct?(%Type{
               @bare
               | fields: [],
                 instance_of: AshRpc.Test.EmptyStats
             })

      refute Introspection.untyped_struct?(%Type{
               @bare
               | fields: [],
                 instance_of: AshRpc.Test.Post
             })

      refute Introspection.untyped_struct?(%Type{@bare | fields: [%{name: :a, type: @string}]})
      refute Introspection.untyped_struct?(%Type{@plain | instance_of: AshRpc.Test.Post})
      refute Introspection.untyped_struct?(%Type{kind: :map, module: Ash.Type.Map})
      refute Introspection.untyped_struct?(%Type{kind: :term, module: Ash.Type.Term})
      refute Introspection.untyped_struct?(nil)
    end

    test "a :struct whose instance_of is an Ash type is untyped and keeps instance_of" do
      typed = %Type{@bare | name: "TaskStats", instance_of: AshRpc.Test.TaskStats}

      assert Introspection.untyped_struct?(typed)

      assert {[], %Type{instance_of: AshRpc.Test.TaskStats}} =
               Introspection.find_untyped_struct(typed, @none)
    end

    test "find_untyped_root/2 returns the first root that reaches one, root prefixed" do
      roots = [
        {"argument :name", @string, "accepts"},
        {"argument :sessions", %Type{kind: :array, item_type: @plain}, "accepts"},
        {"returns", @bare, "returns"}
      ]

      assert Introspection.find_untyped_root(roots, @none) ==
               {["argument :sessions", []], @plain, "accepts"}

      assert Introspection.find_untyped_root([{"returns", nil, "returns"}], @none) == nil
    end

    test "the node itself, array items, typed fields, tuple elements and union members" do
      assert Introspection.find_untyped_struct(@plain, @none) == {[], @plain}

      assert Introspection.find_untyped_struct(%Type{kind: :array, item_type: @plain}, @none) ==
               {[[]], @plain}

      map = %Type{
        kind: :map,
        module: Ash.Type.Map,
        fields: [%{name: :label, type: @string}, %{name: :session, type: @plain}]
      }

      assert Introspection.find_untyped_struct(map, @none) == {[:session], @plain}

      tuple = %Type{
        kind: :tuple,
        module: Ash.Type.Tuple,
        element_types: [%{name: :s, type: @bare}]
      }

      assert Introspection.find_untyped_struct(tuple, @none) == {[:s], @bare}

      union = %Type{
        kind: :union,
        module: Ash.Type.Union,
        members: [%{name: :label, type: @string}, %{name: :session, type: @plain}]
      }

      assert Introspection.find_untyped_struct(union, @none) == {[:session], @plain}

      clean = %Type{kind: :array, item_type: %Type{map | fields: [%{name: :l, type: @string}]}}
      assert Introspection.find_untyped_struct(clean, @none) == nil
    end

    test "named types, and recursive named types terminate" do
      named = %Type{@plain | module: MyApp.SessionType}
      lookups = %{@none | type_lookup: %{MyApp.SessionType => named}}
      ref = %Type{kind: :type_ref, module: MyApp.SessionType}
      assert Introspection.find_untyped_struct(ref, lookups) == {[], named}

      tree_ref = %Type{kind: :type_ref, module: MyApp.Tree}

      tree = %Type{
        kind: :map,
        module: MyApp.Tree,
        fields: [
          %{name: :label, type: @string},
          %{name: :children, type: %Type{kind: :array, item_type: tree_ref}}
        ]
      }

      tree_lookups = %{@none | type_lookup: %{MyApp.Tree => tree}}
      assert Introspection.find_untyped_struct(tree_ref, tree_lookups) == nil
    end

    test "resource fields, calculation arguments, exposed relationships, cycles" do
      calc = %Field{
        name: :score,
        kind: :calculation,
        type: @string,
        arguments: [%Argument{name: :token, type: @plain}]
      }

      a = resource(MyApp.A, %{score: calc})
      node = %Type{kind: :resource, module: MyApp.A, resource_module: MyApp.A}

      assert Introspection.find_untyped_struct(node, %{@none | resource_lookup: %{MyApp.A => a}}) ==
               {[:score, :token], @plain}

      b = resource(MyApp.B, %{session: attr(:session, @plain)})
      rel = %Relationship{name: :bs, cardinality: :many, destination: MyApp.B}
      a = resource(MyApp.A, %{}, %{bs: rel})
      lookups = %{@none | resource_lookup: %{MyApp.A => a, MyApp.B => b}}
      assert Introspection.find_untyped_struct(node, lookups) == {[:bs, :session], @plain}

      unexposed = %{
        lookups
        | resource_lookup: %{MyApp.A => a, MyApp.B => resource(MyApp.B, b.fields, %{}, false)}
      }

      assert Introspection.find_untyped_struct(node, unexposed) == nil

      back = %Relationship{name: :a, cardinality: :one, destination: MyApp.A}

      cycle = %{
        @none
        | resource_lookup: %{MyApp.A => a, MyApp.B => resource(MyApp.B, %{}, %{a: back})}
      }

      assert Introspection.find_untyped_struct(node, cycle) == nil
    end

    test "fields are walked in name order" do
      # More than 32 keys, so the map itself iterates in hash order.
      names = for i <- 10..49, do: String.to_atom("f#{i}")
      fields = Map.new(names, &{&1, attr(&1, @plain)})
      lookups = %{@none | resource_lookup: %{MyApp.A => resource(MyApp.A, fields)}}
      node = %Type{kind: :resource, module: MyApp.A, resource_module: MyApp.A}
      assert Introspection.find_untyped_struct(node, lookups) == {[:f10], @plain}
    end

    test "embedded resource nodes, missing resources and nil field types" do
      emb =
        resource(MyApp.E, %{session: attr(:session, @plain), note: attr(:note, nil)}, %{}, false)

      node = %Type{kind: :embedded_resource, module: MyApp.E, resource_module: MyApp.E}

      assert Introspection.find_untyped_struct(node, %{@none | resource_lookup: %{MyApp.E => emb}}) ==
               {[:session], @plain}

      assert Introspection.find_untyped_struct(node, @none) == nil
      assert Introspection.find_untyped_struct(nil, @none) == nil
    end

    test "a standalone embedded entry falls back to its own resource definition" do
      emb = resource(MyApp.E, %{session: attr(:session, @plain)}, %{}, false)

      node = %Type{
        kind: :embedded_resource,
        module: MyApp.E,
        resource_module: MyApp.E,
        resource: emb
      }

      assert Introspection.find_untyped_struct(node, @none) == {[:session], @plain}
    end

    defp custom(module, constraints \\ []),
      do: %Type{kind: :unknown, name: inspect(module), module: module, constraints: constraints}

    test "composite custom types: entries by name, storage keys, arrays, nested custom types" do
      assert {[:point], %Type{instance_of: AshRpc.Test.PlainSession}} =
               Introspection.find_untyped_struct(custom(AshRpc.Test.PlainPoint), @none)

      assert {[:point], _} =
               Introspection.find_untyped_struct(custom(AshRpc.Test.StoredPoint), @none)

      assert {[:points, []], _} =
               Introspection.find_untyped_struct(custom(AshRpc.Test.PlainPoints), @none)

      assert {[:outer, :point], _} =
               Introspection.find_untyped_struct(custom(AshRpc.Test.OuterPoint), @none)

      assert {[:point], %Type{instance_of: AshRpc.Test.TaskStats}} =
               Introspection.find_untyped_struct(custom(AshRpc.Test.TypedStructPoint), @none)

      wrapped = %Type{
        kind: :map,
        name: "Map",
        module: Ash.Type.Map,
        fields: [%{name: :wrap, type: custom(AshRpc.Test.PlainPoint)}]
      }

      assert {[:wrap, :point], _} = Introspection.find_untyped_struct(wrapped, @none)
    end

    test "a NewType over a composite custom type, through :type_ref" do
      ref = %Type{
        kind: :type_ref,
        name: "PlainPointNewType",
        module: AshRpc.Test.PlainPointNewType
      }

      assert {[:point], %Type{instance_of: AshRpc.Test.PlainSession}} =
               Introspection.find_untyped_struct(ref, @none)
    end

    test "a NewType over a composite custom type uses the constraints of its :type_ref" do
      ref = fn constraints ->
        %Type{
          kind: :type_ref,
          name: "ConstrainedPointNewType",
          module: AshRpc.Test.ConstrainedPointNewType,
          constraints: constraints
        }
      end

      assert {[:point], %Type{instance_of: AshRpc.Test.PlainSession}} =
               Introspection.find_untyped_struct(ref.(plain?: true), @none)

      assert Introspection.find_untyped_struct(ref.(plain?: false), @none) == nil
      assert Introspection.find_untyped_struct(ref.([]), @none) == nil

      # A second use of the same NewType with other constraints is still walked.
      pair = %Type{
        kind: :map,
        name: "Map",
        module: Ash.Type.Map,
        fields: [
          %{name: :clean, type: ref.(plain?: false)},
          %{name: :plain, type: ref.(plain?: true)}
        ]
      }

      assert {[:plain, :point], _} = Introspection.find_untyped_struct(pair, @none)
    end

    @tag timeout: 10_000
    test "a custom type that nests itself with changing constraints raises" do
      assert_raise ArgumentError,
                   "AshRpc.Test.DeepeningPoint nests itself more than 32 levels deep with " <>
                     "changing constraints, so its composite_types/1 entries can't be walked " <>
                     "to an end",
                   fn ->
                     Introspection.find_untyped_struct(custom(AshRpc.Test.DeepeningPoint), @none)
                   end
    end

    test "the nesting limit counts along the path, not across siblings" do
      siblings = %Type{
        kind: :map,
        name: "Map",
        module: Ash.Type.Map,
        fields:
          for i <- 1..40 do
            %{name: :"p#{i}", type: custom(AshRpc.Test.ConstrainedPoint, plain?: false, tag: i)}
          end
      }

      assert Introspection.find_untyped_struct(siblings, @none) == nil
    end

    test "custom types that aren't composite, aren't Ash types or can't be loaded are opaque" do
      for type <- [
            custom(AshRpc.Test.TaskStatsPoint),
            custom(AshRpc.Test.Palette),
            custom(AshRpc.Test.DisabledPoint),
            custom(AshRpc.Test.TypedStructFieldsPoint),
            custom(String),
            custom(AshRpc.Test.NoSuchType),
            %Type{kind: :unknown, name: "Unknown", module: nil}
          ],
          do: assert(Introspection.find_untyped_struct(type, @none) == nil, inspect(type))
    end

    @tag timeout: 10_000
    test "the custom-type visited key includes constraints; recursive custom types terminate" do
      # Same module twice: a key without constraints would skip the second entry.
      pair = %Type{
        kind: :map,
        name: "Map",
        module: Ash.Type.Map,
        fields: [
          %{name: :clean, type: custom(AshRpc.Test.ConstrainedPoint, plain?: false)},
          %{name: :plain, type: custom(AshRpc.Test.ConstrainedPoint, plain?: true)}
        ]
      }

      assert {[:plain, :point], %Type{instance_of: AshRpc.Test.PlainSession}} =
               Introspection.find_untyped_struct(pair, @none)

      assert Introspection.find_untyped_struct(custom(AshRpc.Test.RecursivePoint), @none) == nil
    end

    test "malformed composite entries are skipped; a raising callback raises" do
      assert Introspection.find_untyped_struct(custom(AshRpc.Test.MalformedPoint), @none) == nil

      assert_raise ArgumentError, "composite?/1 raised", fn ->
        Introspection.find_untyped_struct(custom(AshRpc.Test.RaisingPoint), @none)
      end
    end
  end

  describe "untyped data" do
    alias Ash.Info.Manifest.Type

    @map %Type{kind: :map, name: "Map", module: Ash.Type.Map}
    @term %Type{kind: :term, name: "Term", module: Ash.Type.Term}
    @str %Type{kind: :string, name: "String", module: Ash.Type.String}

    test "untyped_data_type?/2: unconstrained maps, Ash.Type.Term, arrays and named types of them" do
      shaped = %Type{@map | fields: [%{name: :a, type: @str}]}

      lookup = %{
        MyApp.Blob => %Type{@map | module: MyApp.Blob},
        MyApp.Shaped => %Type{shaped | module: MyApp.Shaped}
      }

      for type <- [
            @map,
            %Type{@map | fields: []},
            @term,
            %Type{kind: :array, item_type: @map},
            %Type{kind: :array, item_type: @term},
            %Type{kind: :type_ref, module: MyApp.Blob}
          ],
          do: assert(Introspection.untyped_data_type?(type, lookup), inspect(type))

      for type <- [
            shaped,
            %Type{kind: :type_ref, module: MyApp.Shaped},
            %Type{kind: :term, name: "Vector", module: Ash.Type.Vector},
            %Type{kind: :struct, name: "Struct", module: Ash.Type.Struct},
            %Type{kind: :array, item_type: @str},
            @str,
            nil
          ],
          do: refute(Introspection.untyped_data_type?(type, lookup), inspect(type))
    end
  end
end
