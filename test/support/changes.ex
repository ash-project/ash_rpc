# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Changes.Metadata do
  @moduledoc false

  @doc "The metadata values every `*_with_metadata` Post action sets."
  def put(record) do
    record
    |> Ash.Resource.put_metadata(:total_score, 42)
    |> Ash.Resource.put_metadata(:meta_1, "m1")
    |> Ash.Resource.put_metadata(:is_cached?, true)
    |> Ash.Resource.put_metadata(:breakdown, %{top_score: 9, tag_names: ["a", "b"]})
    |> Ash.Resource.put_metadata(:extra, %{
      "_id" => "x-1",
      "snake_key" => %{"_rev" => 1, "nested_key" => "v"}
    })
  end
end

defmodule AshRpc.Test.Changes.PutMetadataOnRead do
  @moduledoc false
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, records ->
      {:ok, Enum.map(records, &AshRpc.Test.Changes.Metadata.put/1)}
    end)
  end
end

defmodule AshRpc.Test.Changes.PutMetadataOnResult do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      {:ok, AshRpc.Test.Changes.Metadata.put(record)}
    end)
  end
end

defmodule AshRpc.Test.Changes.MergeData do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :data) do
      nil ->
        changeset

      data ->
        merged = Map.merge(changeset.data.data || %{}, data)
        Ash.Changeset.change_attribute(changeset, :data, merged)
    end
  end
end
