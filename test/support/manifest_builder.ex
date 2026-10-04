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
    {"page_ledgers", AshRpc.Test.Ledger, :paged},
    # Get actions
    {"get_post", AshRpc.Test.Post, :read, get?: true},
    {"get_post_by_slug", AshRpc.Test.Post, :get_by_slug, get_by: [:slug]},
    {"get_post_by_slug_nullable", AshRpc.Test.Post, :get_by_slug,
     get_by: [:slug], not_found_error?: false},
    {"get_post_by_slug_and_title", AshRpc.Test.Post, :get_by_slug, get_by: [:slug, :title]},
    # Filter/sort flags
    {"list_posts_no_filter", AshRpc.Test.Post, :read, enable_filter?: false},
    {"list_posts_no_sort", AshRpc.Test.Post, :read, enable_sort?: false},
    {"list_posts_no_filter_no_sort", AshRpc.Test.Post, :read,
     enable_filter?: false, enable_sort?: false},
    {"list_rated_comments_no_filter_no_sort", AshRpc.Test.Comment, :rated,
     enable_filter?: false, enable_sort?: false},
    # Load restrictions
    {"list_posts_allow_author", AshRpc.Test.Post, :read, load_restrictions: {:allow, [:author]}},
    {"list_posts_allow_nested", AshRpc.Test.Post, :read,
     load_restrictions: {:allow, [comments: [:post]]}},
    {"list_posts_allow_nested_calc", AshRpc.Test.Post, :read,
     load_restrictions: {:allow, [author: [:is_prolific?]]}},
    {"list_posts_deny_author", AshRpc.Test.Post, :read, load_restrictions: {:deny, [:author]}},
    {"list_posts_deny_nested", AshRpc.Test.Post, :read,
     load_restrictions: {:deny, [comments: [:post]]}},
    {"list_posts_deny_nested_calc", AshRpc.Test.Post, :read,
     load_restrictions: {:deny, [author: [:is_prolific?]]}},
    {"list_comments_allow_post", AshRpc.Test.Comment, :read,
     load_restrictions: {:allow, [:post]}},
    {"list_comments_keyset_allow_post", AshRpc.Test.Comment, :keyset_only,
     load_restrictions: {:allow, [:post]}},
    # Action metadata
    {"read_posts_with_metadata", AshRpc.Test.Post, :read_with_metadata,
     exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
     metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
    {"read_posts_with_some_metadata", AshRpc.Test.Post, :read_with_metadata,
     exposed_metadata_fields: [:total_score, :meta_1], metadata_field_names: %{meta_1: "meta1"}},
    {"read_posts_without_metadata", AshRpc.Test.Post, :read_with_metadata,
     exposed_metadata_fields: []},
    {"create_post_with_metadata", AshRpc.Test.Post, :create_with_metadata,
     exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
     metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
    {"update_post_with_metadata", AshRpc.Test.Post, :update_with_metadata,
     exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
     metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
    {"destroy_post_with_metadata", AshRpc.Test.Post, :destroy_with_metadata,
     exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
     metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
    {"create_post_without_metadata", AshRpc.Test.Post, :create_with_metadata,
     exposed_metadata_fields: []},
    # Identities and actor-scoped mutations
    {"update_post_by_slug", AshRpc.Test.Post, :update, identities: [:unique_slug]},
    {"update_author", AshRpc.Test.Author, :update},
    {"destroy_author", AshRpc.Test.Author, :destroy},
    {"update_author_by_identity", AshRpc.Test.Author, :update,
     identities: [:_primary_key, :name_active]},
    {"update_me", AshRpc.Test.Author, :update_me, identities: [], read_action: :me},
    {"destroy_me", AshRpc.Test.Author, :destroy_me, identities: [], read_action: :me},
    # Unconstrained maps
    {"merge_post_data", AshRpc.Test.Post, :merge_data},
    {"echo_map", AshRpc.Test.Post, :echo_map},
    # Nested query options and pagination
    {"create_comment", AshRpc.Test.Comment, :create},
    {"list_comments", AshRpc.Test.Comment, :read},
    {"create_tag", AshRpc.Test.Tag, :create},
    {"create_post_tag", AshRpc.Test.PostTag, :create},
    # Multitenancy
    {"list_notes", AshRpc.Test.Note, :read},
    {"create_note", AshRpc.Test.Note, :create},
    {"create_note_reply", AshRpc.Test.NoteReply, :create}
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
      for row <- @entrypoints do
        {name, resource, action, entry_opts} = normalize(row)

        %{
          resource: resource,
          action: action,
          config: %{ash_rpc_test: %{name: name, opts: entry_opts}}
        }
      end

    entrypoints
    |> generate!()
    |> AshRpc.Manifest.Decorator.decorate(AshRpc.Test.MappingSource, opts)
  end

  defp normalize({name, resource, action}), do: {name, resource, action, []}
  defp normalize({_name, _resource, _action, _opts} = row), do: row
end
