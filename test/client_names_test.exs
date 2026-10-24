# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ClientNamesTest do
  use ExUnit.Case, async: true

  alias AshRpc.ClientNames
  alias AshRpc.Test.{Author, ManifestBuilder, Post}

  @upcase {AshRpc.Test.Formatters, :upcase}

  setup_all do
    runtimes =
      for f <- [:camel_case, :pascal_case, :snake_case, @upcase], into: %{} do
        {f, AshRpc.Runtime.from_manifest(ManifestBuilder.build(output_formatter: f))}
      end

    %{rt: runtimes}
  end

  defp n(name, f), do: AshRpc.FieldFormatter.format_field_name(name, f)

  defp expected_keys(rt),
    do: AshRpc.InputFormatter.expected_keys(rt.action_lookup[{Post, :create}], Post, rt)

  defp input_type(rt, resource, action, input),
    do: Enum.find(rt.action_lookup[{resource, action}].inputs, &(&1.name == input)).type

  for f <- [:camel_case, :pascal_case, :snake_case, {AshRpc.Test.Formatters, :upcase}] do
    @f f
    describe "under #{inspect(f)}" do
      test "resource fields, calc args, inputs and vocabulary resolve to internal atoms", %{
        rt: rts
      } do
        rt = rts[@f]
        assert ClientNames.resource_field(rt, Post, n(:view_count, @f)) == {:ok, :view_count}
        assert ClientNames.resource_field(rt, Post, n(:comments, @f)) == {:ok, :comments}

        assert ClientNames.calc_arg(rt, Post, :excerpt, n(:omission_text, @f)) ==
                 {:ok, :omission_text}

        assert Map.fetch(expected_keys(rt), n(:view_count, @f)) == {:ok, :view_count}

        assert ClientNames.vocabulary(rt, :params, n(:get_by, @f)) == {:ok, :get_by}

        assert ClientNames.vocabulary(rt, :filter_ops, n(:greater_than, @f)) ==
                 {:ok, :greater_than}
      end

      test "inline type fields and union members resolve", %{rt: rts} do
        rt = rts[@f]
        union = input_type(rt, AshRpc.Test.Widget, :create, :attachments).item_type
        file = Enum.find(union.members, &(&1.name == :file)).type

        assert ClientNames.union_member(rt, union, n(:file, @f)) == {:ok, :file}
        assert ClientNames.type_field(rt, file, n(:mime_type, @f)) == {:ok, :mime_type}
      end
    end
  end

  test "overrides win over formatted names", %{rt: rts} do
    rt = rts[:snake_case]
    assert ClientNames.resource_field(rt, Author, "isActive") == {:ok, :is_active?}
    assert ClientNames.resource_field(rt, Author, "is_active?") == :error
  end

  test "a non-client casing misses", %{rt: rts} do
    rt = rts[:camel_case]
    assert ClientNames.resource_field(rt, Post, "view_count") == :error
    assert ClientNames.calc_arg(rt, Post, :excerpt, "omission_text") == :error
    assert ClientNames.vocabulary(rt, :params, "get_by") == :error
    assert Map.fetch(expected_keys(rt), "view_count") == :error
  end

  test "atom keys pass through", %{rt: rts} do
    rt = rts[:camel_case]
    assert ClientNames.resource_field(rt, Post, :view_count) == {:ok, :view_count}
    assert ClientNames.vocabulary(rt, :page, :limit) == {:ok, :limit}
  end

  test "an undecorated type absent from the lookup misses", %{rt: rts} do
    type =
      Ash.Info.Manifest.Generator.TypeResolver.resolve(Ash.Type.Map,
        fields: [mime_type: [type: :string]]
      )

    assert ClientNames.type_field(rts[:camel_case], type, "mimeType") == :error
  end

  test "an undecorated reference resolves through the type lookup", %{rt: rts} do
    rt = rts[:camel_case]
    ref = %Ash.Info.Manifest.Type{kind: :type_ref, module: AshRpc.Test.PostStats}
    assert ClientNames.type_field(rt, ref, "wordCount1") == {:ok, :word_count_1}
  end

  describe "named predicates" do
    test "decorated resources and types are named; others are not", %{rt: rts} do
      rt = rts[:camel_case]
      assert ClientNames.resource_named?(rt, Post)
      refute ClientNames.resource_named?(rt, AshRpc.Test.Secret)

      stats = Ash.Info.Manifest.get_field(rt.resource_lookup, Post, :stats).type
      assert ClientNames.type_named?(rt, stats)

      raw =
        Ash.Info.Manifest.Generator.TypeResolver.resolve(:map, fields: [a_b: [type: :integer]])

      refute ClientNames.type_named?(rt, raw)
      refute ClientNames.type_named?(rt, nil)
    end
  end
end

defmodule AshRpc.ClientNamesAtomTest do
  # The atom table is VM-wide: any test that loads a module or creates an atom
  # concurrently changes the count, so this runs alone.
  use ExUnit.Case, async: false

  alias AshRpc.ClientNames
  alias AshRpc.Test.Post

  test "unknown client strings never create atoms" do
    rt = AshRpc.Runtime.new(AshRpc.Test.Profile)
    names = for i <- 1..200, do: "neverSeenName#{i}_#{System.unique_integer([:positive])}"
    before = :erlang.system_info(:atom_count)

    for name <- names do
      assert ClientNames.resource_field(rt, Post, name) == :error
      assert ClientNames.vocabulary(rt, :filter_ops, name) == :error
    end

    assert :erlang.system_info(:atom_count) == before
  end
end
