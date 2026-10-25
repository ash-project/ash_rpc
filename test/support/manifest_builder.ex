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
    {"read_posts_with_amount_meta", AshRpc.Test.Post, :read_with_amount_meta,
     exposed_metadata_fields: [:amount]},
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
    {"update_post_scoped", AshRpc.Test.Post, :update, read_action: :read_unviewed},
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
    {"update_post_tag", AshRpc.Test.PostTag, :update},
    {"destroy_post_tag", AshRpc.Test.PostTag, :destroy},
    # Multitenancy
    {"list_notes", AshRpc.Test.Note, :read},
    {"create_note", AshRpc.Test.Note, :create},
    {"create_note_reply", AshRpc.Test.NoteReply, :create},
    # Private attributes and vectors
    {"create_account", AshRpc.Test.Account, :create},
    {"list_accounts", AshRpc.Test.Account, :read},
    # Unions
    {"create_widget", AshRpc.Test.Widget, :create},
    {"list_widgets", AshRpc.Test.Widget, :read},
    {"get_widget", AshRpc.Test.Widget, :read, get?: true},
    # Keyword and tuple
    {"create_place", AshRpc.Test.Place, :create},
    {"list_places", AshRpc.Test.Place, :read},
    {"get_place", AshRpc.Test.Place, :read, get?: true},
    {"place_keyword_options", AshRpc.Test.Place, :keyword_options},
    {"place_coordinates_info", AshRpc.Test.Place, :coordinates_info},
    # Embedded, custom and typed-struct values
    {"create_project", AshRpc.Test.Project, :create},
    {"update_project", AshRpc.Test.Project, :update},
    {"list_projects", AshRpc.Test.Project, :read},
    {"get_project", AshRpc.Test.Project, :read, get?: true},
    {"create_project_note", AshRpc.Test.ProjectNote, :create},
    {"process_project_meta", AshRpc.Test.Project, :process_meta},
    {"process_project_meta_batch", AshRpc.Test.Project, :process_meta_batch},
    # Generic-action returns and struct arguments
    {"catalog_search_posts", AshRpc.Test.Catalog, :search_posts},
    {"catalog_post_ids", AshRpc.Test.Catalog, :post_ids},
    {"catalog_find_post_via_reactor", AshRpc.Test.Catalog, :find_post_via_reactor},
    {"catalog_task_stats", AshRpc.Test.Catalog, :task_stats},
    {"catalog_task_stats_list", AshRpc.Test.Catalog, :task_stats_list},
    {"catalog_stats_list", AshRpc.Test.Catalog, :stats_list},
    {"catalog_raw_rows", AshRpc.Test.Catalog, :raw_rows},
    {"catalog_publication_date", AshRpc.Test.Catalog, :publication_date},
    {"catalog_important_dates", AshRpc.Test.Catalog, :important_dates},
    {"catalog_digest", AshRpc.Test.Catalog, :digest},
    {"catalog_assign", AshRpc.Test.Catalog, :assign},
    {"catalog_assign_many", AshRpc.Test.Catalog, :assign_many},
    {"catalog_redeem_voucher", AshRpc.Test.Catalog, :redeem_voucher},
    {"catalog_struct_summary", AshRpc.Test.Catalog, :struct_summary},
    {"catalog_struct_summaries", AshRpc.Test.Catalog, :struct_summaries},
    # Declared custom types
    {"catalog_amount_result", AshRpc.Test.Catalog, :amount_result},
    {"catalog_string_keyed_palette", AshRpc.Test.Catalog, :string_keyed_palette},
    {"catalog_string_keyed_palette_box", AshRpc.Test.Catalog, :string_keyed_palette_box},
    {"create_swatch", AshRpc.Test.Swatch, :create},
    {"list_swatches", AshRpc.Test.Swatch, :read},
    {"create_swatch_box", AshRpc.Test.SwatchBox, :create},
    {"list_swatch_boxes", AshRpc.Test.SwatchBox, :read},
    # Untyped data, sent as produced
    {"catalog_untyped_records_map", AshRpc.Test.Catalog, :untyped_records_map},
    {"catalog_untyped_records_term", AshRpc.Test.Catalog, :untyped_records_term},
    {"catalog_untyped_records_list", AshRpc.Test.Catalog, :untyped_records_list},
    {"catalog_untyped_value_structs", AshRpc.Test.Catalog, :untyped_value_structs},
    {"catalog_untyped_forbidden_field", AshRpc.Test.Catalog, :untyped_forbidden_field},
    # Input and overrides
    {"create_intake", AshRpc.Test.Intake, :create},
    {"update_intake", AshRpc.Test.Intake, :update},
    {"search_intakes", AshRpc.Test.Intake, :search},
    {"process_intake_data", AshRpc.Test.Intake, :process_data},
    # Required multi-word arguments and mapped update arguments
    {"create_post_for_owner", AshRpc.Test.Post, :create_for_owner},
    {"set_post_viewed", AshRpc.Test.Post, :set_viewed}
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

  @doc """
  Builds a fresh manifest; `opts` are passed to the decorator, apart from
  `:mapping_source` (default `AshRpc.Test.MappingSource`).
  """
  def build(opts \\ []) do
    {mapping_source, opts} = Keyword.pop(opts, :mapping_source, AshRpc.Test.MappingSource)

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
    |> AshRpc.Manifest.Decorator.decorate(mapping_source, opts)
  end

  defp normalize({name, resource, action}), do: {name, resource, action, []}
  defp normalize({_name, _resource, _action, _opts} = row), do: row
end
