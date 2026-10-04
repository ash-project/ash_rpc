# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.TypeClassificationTest do
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest.Type
  alias AshRpc.{Introspection, Runtime}

  setup do
    %{rt: Runtime.new(AshRpc.Test.Profile)}
  end

  defp field_type(resource, field, rt),
    do: Ash.Info.Manifest.get_field(rt.resource_lookup, resource, field).type

  test "has_field_name_overrides?/2 reads decorated types and the mapping source", %{rt: rt} do
    assert Introspection.has_field_name_overrides?(rt, AshRpc.Test.PostStats)
    refute Introspection.has_field_name_overrides?(rt, AshRpc.Test.PostSettings)
    refute Introspection.has_field_name_overrides?(rt, nil)
  end

  test "classify_type/2 categories", %{rt: rt} do
    assert {:typed_struct, %Type{module: AshRpc.Test.PostStats}} =
             Introspection.classify_type(field_type(AshRpc.Test.Post, :stats, rt), rt)

    assert {:resource, AshRpc.Test.PostSettings} =
             Introspection.classify_type(field_type(AshRpc.Test.Post, :settings, rt), rt)

    assert {:array, %Type{kind: :union}} =
             Introspection.classify_type(field_type(AshRpc.Test.Ledger, :entries, rt), rt)

    assert {:union, %Type{kind: :union}} =
             Introspection.classify_type(field_type(AshRpc.Test.Ledger, :count, rt), rt)

    assert {:other, %Type{kind: :string}} =
             Introspection.classify_type(field_type(AshRpc.Test.Post, :title, rt), rt)

    assert {:fields, %Type{kind: :keyword}} =
             Introspection.classify_type(%Type{kind: :keyword, module: Ash.Type.Keyword}, rt)
  end

  test "classify_type/2 resolves a type_ref the manifest doesn't carry", %{rt: rt} do
    rt = %{rt | type_lookup: %{}}

    assert {:typed_struct, %Type{module: AshRpc.Test.PostStats}} =
             Introspection.classify_type(
               %Type{kind: :type_ref, module: AshRpc.Test.PostStats},
               rt
             )
  end
end
