# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.MappingSource do
  @moduledoc false
  @behaviour AshRpc.MappingSource

  @exposed [
    AshRpc.Test.Account,
    AshRpc.Test.Author,
    AshRpc.Test.Catalog,
    AshRpc.Test.ChecklistBlock,
    AshRpc.Test.Comment,
    AshRpc.Test.CommentAttachment,
    AshRpc.Test.Intake,
    AshRpc.Test.IntakeProfile,
    AshRpc.Test.IntakeSection,
    AshRpc.Test.IntakeStatus,
    AshRpc.Test.Ledger,
    AshRpc.Test.Note,
    AshRpc.Test.NoteReply,
    AshRpc.Test.Place,
    AshRpc.Test.Post,
    AshRpc.Test.PostSettings,
    AshRpc.Test.PostTag,
    AshRpc.Test.Project,
    AshRpc.Test.ProjectMeta,
    AshRpc.Test.ProjectMetaDetail,
    AshRpc.Test.ProjectNote,
    AshRpc.Test.Tag,
    AshRpc.Test.TextBlock,
    AshRpc.Test.Widget
  ]

  @impl true
  def output_formatter, do: :camel_case

  @impl true
  def exposed_resource?(resource), do: resource in @exposed

  @impl true
  def field_names(AshRpc.Test.Author), do: %{is_active?: "isActive", is_prolific?: "isProlific"}
  def field_names(AshRpc.Test.ChecklistBlock), do: %{is_active?: "isActive"}
  def field_names(AshRpc.Test.Intake), do: %{is_active?: "isActive", version_1: "version1"}

  def field_names(AshRpc.Test.IntakeProfile),
    do: %{bio_text_1: "bioText1", is_public?: "isPublic"}

  def field_names(AshRpc.Test.IntakeSection), do: %{level_1: "level1"}
  def field_names(AshRpc.Test.IntakeStatus), do: %{is_final?: "isFinal"}
  # Unexposed: decoration must never ask for its overrides
  def field_names(AshRpc.Test.QuoteBlock), do: raise("field_names/1 called for QuoteBlock")
  def field_names(_resource), do: %{}

  @impl true
  def argument_names(AshRpc.Test.Post, :word_count), do: %{text: "body"}

  def argument_names(AshRpc.Test.Post, :set_viewed), do: %{is_viewed?: "isViewed"}

  def argument_names(AshRpc.Test.Intake, :search),
    do: %{include_deleted?: "includeDeleted", filter_by_1?: "filterBy1"}

  def argument_names(AshRpc.Test.QuoteBlock, _action),
    do: raise("argument_names/2 called for QuoteBlock")

  def argument_names(_resource, _action), do: %{}

  @impl true
  def type_field_names(AshRpc.Test.PostStats),
    do: %{word_count_1: "wordCount1", is_featured?: "isFeatured"}

  def type_field_names(AshRpc.Test.GeoPoint),
    do: %{lat_1: "lat1", lng_1: "lng1", is_verified?: "isVerified"}

  def type_field_names(AshRpc.Test.ProjectStats), do: %{all_done?: "allDone"}

  def type_field_names(AshRpc.Test.TaskStats),
    do: %{completed?: "completed", is_urgent?: "isUrgent"}

  def type_field_names(AshRpc.Test.IntakeStats),
    do: %{total_count_1: "totalCount1", is_complete?: "isComplete"}

  def type_field_names(AshRpc.Test.IntakeDeep), do: %{is_enabled_1?: "isEnabled1"}

  def type_field_names(AshRpc.Test.IntakeInner),
    do: %{max_retries_1: "maxRetries1", is_cached?: "isCached"}

  def type_field_names(AshRpc.Test.IntakePrefs),
    do: %{theme_1: "theme1", is_dark_mode?: "isDarkMode"}

  def type_field_names(AshRpc.Test.IntakeData), do: %{is_cached?: "isCached"}
  def type_field_names(AshRpc.Test.IntakeInput), do: %{is_valid?: "isValid"}

  def type_field_names(_type), do: nil

  # Row opts from `ManifestBuilder` set non-default entrypoint fields; struct!/2
  # raises KeyError on a typo so a bad row fails the manifest build.
  @impl true
  def entrypoint(%Ash.Info.Manifest.Entrypoint{config: %{ash_rpc_test: %{name: name} = cfg}} = e) do
    struct!(
      %AshRpc.Entrypoint{
        name: name,
        domain: AshRpc.Test.Domain,
        resource: e.resource,
        action: e.action.name
      },
      Map.get(cfg, :opts, [])
    )
  end

  def entrypoint(_entrypoint), do: nil
end
