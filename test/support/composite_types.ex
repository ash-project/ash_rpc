# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.PlainPoint do
  @moduledoc false
  # A composite type whose `point` entry is a plain struct.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_),
    do: [{:label, :string, []}, {:point, :struct, [instance_of: AshRpc.Test.PlainSession]}]
end

defmodule AshRpc.Test.TypedStructPoint do
  @moduledoc false
  # A composite type whose `point` entry names a TypedStruct through `instance_of`.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_), do: [{:point, :struct, [instance_of: AshRpc.Test.TaskStats]}]
end

defmodule AshRpc.Test.StoredPoint do
  @moduledoc false
  # A composite type whose plain-struct entry has a storage key.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_),
    do: [{:point, :point_key, :struct, [instance_of: AshRpc.Test.PlainSession]}]
end

defmodule AshRpc.Test.PlainPoints do
  @moduledoc false
  # A composite type whose `points` entry is an array of plain structs.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_),
    do: [{:points, {:array, :struct}, [items: [instance_of: AshRpc.Test.PlainSession]]}]
end

defmodule AshRpc.Test.OuterPoint do
  @moduledoc false
  # A composite type whose `outer` entry is another composite type.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_), do: [{:outer, AshRpc.Test.PlainPoint, []}]
end

defmodule AshRpc.Test.TaskStatsPoint do
  @moduledoc false
  # A composite type whose `point` entry is the TypedStruct itself: typed.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_), do: [{:point, AshRpc.Test.TaskStats, []}]
end

defmodule AshRpc.Test.DisabledPoint do
  @moduledoc false
  # Declares a plain-struct entry but isn't composite: the entries aren't read.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: false
  @impl true
  def composite_types(_), do: [{:point, :struct, [instance_of: AshRpc.Test.PlainSession]}]
end

defmodule AshRpc.Test.RecursivePoint do
  @moduledoc false
  # A composite type that lists itself: the walk terminates.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_), do: [{:label, :string, []}, {:next, AshRpc.Test.RecursivePoint, []}]
end

defmodule AshRpc.Test.MalformedPoint do
  @moduledoc false
  # A composite type with entries in no documented shape: they are skipped.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true
  @impl true
  def composite_types(_),
    do: [:not_an_entry, {:too, :short}, {:odd, "not a type", []}, {:label, :string, []}]
end

defmodule AshRpc.Test.PlainPointNewType do
  @moduledoc false
  # A NewType over a composite type: its callbacks delegate to `PlainPoint`.
  use Ash.Type.NewType, subtype_of: AshRpc.Test.PlainPoint
end

defmodule AshRpc.Test.TypedStructFieldsPoint do
  @moduledoc false
  # Describes a plain-struct field only through `typed_struct_fields/0`, which
  # isn't an Ash callback: the type stays opaque.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  def typed_struct_fields,
    do: [point: [type: :struct, constraints: [instance_of: AshRpc.Test.PlainSession]]]
end

defmodule AshRpc.Test.ConstrainedPoint do
  @moduledoc false
  # A composite type whose entries depend on its `plain?` constraint.
  use Ash.Type

  @impl true
  def constraints, do: [plain?: [type: :boolean, default: false]]

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true

  @impl true
  def composite_types(constraints) do
    if constraints[:plain?],
      do: [{:point, :struct, [instance_of: AshRpc.Test.PlainSession]}],
      else: [{:point, AshRpc.Test.TaskStats, []}]
  end
end

defmodule AshRpc.Test.RaisingPoint do
  @moduledoc false
  # A custom type whose `composite?/1` raises: the walk doesn't rescue it.
  use Ash.Type

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: raise(ArgumentError, "composite?/1 raised")
end

defmodule AshRpc.Test.PointLog do
  @moduledoc false
  # Records with a composite attribute whose `point` entry is a plain struct.
  # No wire entrypoint by default: decoration rejects its read.
  use Ash.Resource, domain: AshRpc.Test.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :location, AshRpc.Test.PlainPoint, public?: true
  end

  actions do
    defaults [:read]
  end
end

defmodule AshRpc.Test.ConstrainedPointNewType do
  @moduledoc false
  # A NewType over `ConstrainedPoint`: the `plain?` constraint given where it
  # is used decides its entries for the untyped walk. Declared fields come
  # from the default constraints.
  use Ash.Type.NewType, subtype_of: AshRpc.Test.ConstrainedPoint
end

defmodule AshRpc.Test.DeepeningPoint do
  @moduledoc false
  # A composite type that lists itself with a deeper `depth` each time: every
  # level has new constraints, so only a nesting limit stops the untyped walk.
  # Declared, it is one recursive named type.
  use Ash.Type

  @impl true
  def constraints, do: [depth: [type: :integer, default: 0]]

  @impl true
  def storage_type(_), do: :map
  @impl true
  def cast_input(value, _), do: {:ok, value}
  @impl true
  def cast_stored(value, _), do: {:ok, value}
  @impl true
  def dump_to_native(value, _), do: {:ok, value}

  @impl true
  def composite?(_), do: true

  @impl true
  def composite_types(constraints),
    do: [{:next, __MODULE__, [depth: (constraints[:depth] || 0) + 1]}]
end
