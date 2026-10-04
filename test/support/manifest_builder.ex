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
    {"list_authors", AshRpc.Test.Author, :read},
    {"create_author", AshRpc.Test.Author, :create}
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

  @doc "Builds a fresh manifest; `opts` are passed to the decorator."
  def build(opts \\ []) do
    entrypoints =
      for {name, resource, action} <- @entrypoints do
        %{resource: resource, action: action, config: %{ash_rpc_test: %{name: name}}}
      end

    {:ok, manifest} =
      Ash.Info.Manifest.Generator.generate(otp_app: :ash_rpc, action_entrypoints: entrypoints)

    AshRpc.Manifest.Decorator.decorate(manifest, AshRpc.Test.MappingSource, opts)
  end
end
