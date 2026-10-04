# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ManifestBuilder do
  @moduledoc false

  @entrypoints [
    {"list_posts", AshRpc.Test.Post, :read},
    {"create_post", AshRpc.Test.Post, :create},
    {"update_post", AshRpc.Test.Post, :update},
    {"destroy_post", AshRpc.Test.Post, :destroy},
    {"word_count", AshRpc.Test.Post, :word_count},
    {"stats_summary", AshRpc.Test.Post, :stats_summary},
    {"totals", AshRpc.Test.Post, :totals},
    {"location", AshRpc.Test.Post, :location},
    {"payload", AshRpc.Test.Post, :payload},
    {"ping", AshRpc.Test.Post, :ping},
    {"list_authors", AshRpc.Test.Author, :read},
    {"create_author", AshRpc.Test.Author, :create},
    {"create_ledger", AshRpc.Test.Ledger, :create},
    {"list_ledgers", AshRpc.Test.Ledger, :read},
    {"page_ledgers", AshRpc.Test.Ledger, :paged}
  ]

  @doc "Cached default manifest (camelCase in/out)."
  def manifest do
    case :persistent_term.get({__MODULE__, :manifest}, nil) do
      nil ->
        manifest = build()
        :persistent_term.put({__MODULE__, :manifest}, manifest)
        manifest

      manifest ->
        manifest
    end
  end

  @doc "Undecorated manifest for `entrypoints` (any `:action_entrypoints` form)."
  def generate!(entrypoints) do
    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(otp_app: :ash_rpc, action_entrypoints: entrypoints)

    manifest
  end

  @doc "Builds a fresh manifest; `opts` are passed to the decorator."
  def build(opts \\ []) do
    entrypoints =
      for {name, resource, action} <- @entrypoints do
        %{resource: resource, action: action, config: %{ash_rpc_test: %{name: name}}}
      end

    entrypoints
    |> generate!()
    |> AshRpc.Manifest.Decorator.decorate(AshRpc.Test.MappingSource, opts)
  end
end
