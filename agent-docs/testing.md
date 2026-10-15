<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Testing

How ash_rpc's suite is laid out, how the fixture manifest is built and varied,
and the patterns each kind of test uses. Fixtures (`AshRpc.Test.*`) compile only
in `:test`; run `mix test`, never with a `MIX_ENV=test` prefix.

## Suite Layout

Each group matches a feature doc. Keep this table in sync with the
Documentation Index in `AGENTS.md`.

| Feature doc | Test files |
|-------------|------------|
| [decoration](features/decoration.md) | `test/manifest/decorator_test.exs`, `test/manifest/redecorate_test.exs`, `test/entrypoint_test.exs`, `test/runtime_test.exs`, `test/profile_test.exs` |
| [pipeline](features/pipeline.md) | `test/run_action_test.exs`, `test/validation_test.exs`, `test/context_test.exs`, `test/plug_test.exs`, `test/channel_test.exs`, `test/multitenancy_test.exs`, `test/filter_sort_test.exs`, `test/get_actions_test.exs` |
| [field selection](features/field-selection.md) | `test/field_selector_test.exs`, `test/typed_field_selection_test.exs`, `test/calculations_test.exs`, `test/aggregates_test.exs`, `test/nested_query_opts_test.exs`, `test/load_restrictions_test.exs`, `test/result_output_test.exs`, `test/result_processor_test.exs`, `test/type_classification_test.exs`, `test/union_output_test.exs`, `test/keyword_tuple_test.exs`, `test/typed_struct_test.exs`, `test/generic_returns_test.exs`, `test/embedded_resources_test.exs` |
| [formatting](features/formatting.md) | `test/value_formatter_test.exs`, `test/field_formatter_test.exs`, `test/field_name_translation_test.exs`, `test/union_input_test.exs`, `test/unconstrained_map_test.exs`, `test/complex_input_test.exs` |
| [action metadata](features/action-metadata.md) | `test/action_metadata_test.exs` |
| [errors](features/errors.md) | `test/errors_test.exs`, `test/error_protocol_test.exs`, `test/error_builder_golden_test.exs`, `test/error_formatter_test.exs` |

Five files belong to no feature doc:

- `test/fixtures_test.exs`: smoke tests for the fixtures themselves (ETS
  persistence, the generator seeing the fixture domain, row opts reaching
  `%AshRpc.Entrypoint{}`, an unknown row opt failing the build).
- `test/introspection_test.exs`: `AshRpc.Introspection` helpers (pagination
  predicates, return classification, metadata helpers, `ash_resource?/1`).
- `test/doctest_test.exs`: runs the `iex>` examples in `lib/`. Add a `doctest`
  line when a module gains its first example; examples must run without the
  test fixtures, so they never name `AshRpc.Test.*`.
- `test/security_regression_test.exs`: values that must never reach the wire
  (`%Ash.ForbiddenField{}` contents, unserializable terms in error vars).
- `test/runtime_boundary_test.exs`: Rule 3's source guard. It walks the AST of
  `lib/ash_rpc.ex` and `lib/ash_rpc/**` (decoration excluded) for
  `Ash.Resource.Info`, `Ash.DataLayer` and `Application` env calls, apart from
  an allowlist of value-classification calls; a stale allowlist entry fails too.

## `AshRpc.Test.ManifestBuilder`

`test/support/manifest_builder.ex` is the fixture extension's manifest. It
generates an `Ash.Info.Manifest` from the `@entrypoints` rows and decorates it
with `AshRpc.Test.MappingSource`.

- `manifest/0`: the default manifest (camelCase in and out), built once and
  cached in `:persistent_term`. `AshRpc.Test.Profile` resolves to it. Never
  mutate it; build a variant instead.
- `build/1`: a fresh, decorated manifest; `opts` go to
  `AshRpc.Manifest.Decorator.decorate/3` (e.g. `output_formatter:`).
- `generate!/1`: an **undecorated** manifest for any `:action_entrypoints` form.
  Use it to test decoration itself or the "no decoration" error.

Rows are `{name, resource, action}` or `{name, resource, action, opts}`. The
mapping source's `entrypoint/1` builds the entrypoint with
`struct!(%AshRpc.Entrypoint{…}, opts)`, so row opts set entrypoint fields
directly and a typo fails the build (`test/fixtures_test.exs` "an unknown
entrypoint opt fails the manifest build"):

```elixir
{"get_post_by_slug_nullable", AshRpc.Test.Post, :get_by_slug,
 get_by: [:slug], not_found_error?: false},
{"list_posts_allow_author", AshRpc.Test.Post, :read, load_restrictions: {:allow, [:author]}},
```

See [development workflows](development-workflows.md) for adding a wire action
or a fixture resource.

## Varying the Manifest

Formatters are fixed at decoration (see [decoration](features/decoration.md)).
Changing application config in a test has no effect. Build a variant manifest
and pass it with the `manifest:` option; this is `async: true` safe.

```elixir
manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :pascal_case)
# or: AshRpc.Manifest.redecorate(AshRpc.Test.ManifestBuilder.manifest(), output_formatter: :pascal_case)

assert %{"Success" => true, "Data" => %{"ViewCount" => 0}} =
         AshRpc.run_action(
           AshRpc.Test.Profile,
           %AshRpc.Context{},
           %{"action" => "create_post", "input" => %{"title" => "x"}, "fields" => ["viewCount"]},
           manifest: manifest
         )
```

Asserted by `test/run_action_test.exs` "manifest: option changes output casing".
`redecorate/2` reads only `:input_formatter` and `:output_formatter`
(`test/manifest/redecorate_test.exs`).

The `entrypoint:` option runs a request against an entrypoint struct you pass in
instead of resolving `params["action"]`. To test a variant, take one from the
lookup and change a field (`test/validation_test.exs` "the read_action used for
the lookup is the entrypoint's"):

```elixir
entrypoint = %{
  AshRpc.Manifest.entrypoint_lookup(AshRpc.Test.ManifestBuilder.manifest())["update_post"]
  | read_action: :no_such_read
}

AshRpc.validate_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{"identity" => id, "input" => %{}},
  entrypoint: entrypoint
)
```

## Patterns

Every test module uses `use ExUnit.Case, async: true`. The ETS fixtures are
`private? true`, so each test process sees only its own data and needs no
cleanup.

**Seeding.** Create records with plain Ash calls, as the suite does
(`test/load_restrictions_test.exs` `seed!/0`):

```elixir
author = Ash.create!(AshRpc.Test.Author, %{name: "Ada"})
post = Ash.create!(AshRpc.Test.Post, %{title: "Hello", author_id: author.id})
```

**Wire test.** Call `AshRpc.run_action/4` with a `%AshRpc.Context{}` and assert
on the response map. The source must be a `Plug.Conn`, a `Phoenix.Socket` or an
`%AshRpc.Context{}`; a bare map is not accepted.

```elixir
@profile AshRpc.Test.Profile

defp ctx, do: %AshRpc.Context{}
defp run(params), do: AshRpc.run_action(@profile, ctx(), params)

test "create then read" do
  assert %{"success" => true, "data" => %{"title" => "a"}} =
           run(%{"action" => "create_post", "input" => %{"title" => "a"}, "fields" => ["title"]})
end
```

**Parse only.** To assert on a pipeline reason before it becomes an error map,
stop after stage one with `AshRpc.Pipeline.parse_request/4`
(`test/load_restrictions_test.exs` `parse/1`):

```elixir
defp parse(params) do
  AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)
end

assert {:error, {:filter_not_supported, :top_level, :unsupported}} =
         parse(%{"action" => "get_post", "fields" => ["title"], "filter" => %{"title" => %{"eq" => "Alpha"}}})
```

(`test/filter_sort_test.exs` "a filter on a get entrypoint is unsupported, not disabled".)

**Channel test.** Start the PubSub and `AshRpc.Test.Endpoint`, join
`AshRpc.Test.RpcChannel`, push `"run"`/`"validate"` (`test/channel_test.exs`):

```elixir
import Phoenix.ChannelTest
@endpoint AshRpc.Test.Endpoint

setup_all do
  start_supervised!({Phoenix.PubSub, name: AshRpc.Test.PubSub})
  start_supervised!(AshRpc.Test.Endpoint)
  _ = AshRpc.Test.ManifestBuilder.manifest()
  :ok
end

setup do
  {:ok, _, socket} =
    AshRpc.Test.Socket
    |> socket("user", %{ash_actor: nil, ash_tenant: nil})
    |> subscribe_and_join(AshRpc.Test.RpcChannel, "rpc:lobby")

  %{socket: socket}
end

test "run replies ok with the result body", %{socket: socket} do
  ref = push(socket, "run", %{"action" => "create_post", "input" => %{"title" => "c"}, "fields" => ["title"]})
  assert_reply(ref, :ok, %{"success" => true, "data" => %{"title" => "c"}})
end
```

Warming the cached manifest in `setup_all` keeps the first push inside
`assert_reply`'s timeout.

**Tenant.** Seed with `tenant:`, then send the `tenant` param, or set the tenant
on the source (`%AshRpc.Context{tenant: …}`, `Ash.PlugHelpers.set_tenant/2` on a
conn, or the `ash_tenant` socket assign). The param wins over the source
(`test/multitenancy_test.exs`):

```elixir
Ash.create!(AshRpc.Test.Note, %{title: "one"}, tenant: "w1")

assert %{"success" => true, "data" => [%{"title" => "one"}]} =
         AshRpc.run_action(@profile, %AshRpc.Context{}, %{
           "action" => "list_notes",
           "fields" => ["title"],
           "tenant" => "w1"
         })
```

**Error golden test.** `test/error_builder_golden_test.exs` renders every reason
in `AshRpc.Test.ErrorCases.cases/0` and compares it with the inline `@golden`
map. "the snapshot covers every case" fails if a case has no snapshot entry.
Update `@golden` only for an intentional wire change; add a case to
`test/support/error_cases.ex` when you add an `ErrorBuilder` clause (see
[errors](features/errors.md)).

## Fixtures (`test/support/`)

| File | Purpose |
|------|---------|
| `domain.ex` | `AshRpc.Test.Domain`: the sixteen fixture resources (embedded types are not listed) |
| `mapping_source.ex` | `AshRpc.Test.MappingSource`: `@exposed` list, overrides (`Author` `isActive`/`isProlific`, `word_count` argument `text` → `body`, `set_viewed` argument `is_viewed?` → `isViewed`, `PostStats` `wordCount1`/`isFeatured`, plus the theme overrides listed with each fixture below), row opts → `%AshRpc.Entrypoint{}` via `struct!/2` |
| `manifest_builder.ex` | `AshRpc.Test.ManifestBuilder`: `@entrypoints` wire rows; `manifest/0`, `build/1`, `generate!/1` |
| `profile.ex` | `AshRpc.Test.Profile`: `use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder`, all callbacks default |
| `error_handler_profiles.ex` | Profiles whose `error_handler/1` misbehaves, all backed by `AshRpc.Test.PartialErrorHandler`: `PartialHandlerProfile` (redacts `invalid_attribute`, no clause for anything else), `RaisingHandlerProfile` (raises), `ThrowingHandlerProfile` (throws) |
| `endpoint.ex` | `AshRpc.Test.Socket`, `AshRpc.Test.Endpoint`, and `AshRpc.Test.RpcChannel` (`use AshRpc.Channel`, joins `"rpc:*"`) |
| `error_cases.ex` | `AshRpc.Test.ErrorCases`: one reason per `ErrorBuilder` clause, for the golden test |
| `post.ex` | `AshRpc.Test.Post`: the main resource. Typed-map `stats`, embedded `settings`, unconstrained `data`, `unique_slug` identity; relationships to `author`, unexposed `secret`, `comments` (plus offset-only/keyset-only variants), `tags`; calculations with and without args (`title_shout` is `field? false`); aggregates; metadata actions; a `read_unviewed` read filtered to `view_count == 0` (the `read_action:` of `update_post_scoped`); `unfilterable_comments` / `unsortable_comments` (`filterable?`/`sortable?` false) and `secrets` (has_many to the unexposed `Secret`); `create_for_owner` with a required multi-word `owner_id` (`create_post_for_owner`); `set_viewed` with a mapped `is_viewed?` → `isViewed`, an inline change and a private `audit_note` argument (`set_post_viewed`); generic actions returning `:map`, typed map, tuple, union and nothing |
| `account.ex` | `AshRpc.Test.Account`: non-public `secret` and `internal_notes` attributes, and an `embedding` vector with `dimensions: 3` (`create_account`, `list_accounts`) |
| `author.ex` | `AshRpc.Test.Author`: `is_active?` / `is_prolific?` (name overrides), `post_count` aggregate, `name_active` identity, actor-scoped `me` / `update_me` / `destroy_me` |
| `comment.ex` | `AshRpc.Test.Comment`: has_many target. Union `attachment` (embedded `file` / string `note`), `weighted_rating` calc, reads with offset+keyset, offset-only, keyset-only and a `rated` read filtered by a `min_rating` argument |
| `comment_attachment.ex` | `AshRpc.Test.CommentAttachment`: embedded union member with a `label` calculation |
| `tag.ex` | `AshRpc.Test.Tag`: many_to_many target with a paginated read |
| `post_tag.ex` | `AshRpc.Test.PostTag`: join resource for `Post.tags`, with a composite primary key and a `position` attribute (`create_post_tag`, `update_post_tag`, `destroy_post_tag`) |
| `note.ex` | `AshRpc.Test.Note`: attribute multitenancy (`workspace_id`), has_many `replies` |
| `note_reply.ex` | `AshRpc.Test.NoteReply`: multitenant child of `Note` with a paginated read |
| `ledger.ex` | `AshRpc.Test.Ledger`: union `count` and arrays allowing nil items; `count` deliberately collides with the page-map key (`page_ledgers`) |
| `secret.ex` | `AshRpc.Test.Secret`: in the domain but deliberately **not exposed**, for strict-exposure tests; `post_id` is the destination of `Post.secrets` |
| `post_settings.ex` | `AshRpc.Test.PostSettings`: embedded resource with a `theme_label` calculation |
| `post_stats.ex` | `AshRpc.Test.PostStats`: `Ash.Type.NewType` map with fields `word_count_1` and `is_featured?` (client names via `type_field_names/1`) |
| `calculations.ex` | Module calculations. For `Post`: `Excerpt` (arg `length`), `ScoredStats` (arg `boost`, returns `PostStats`), `SelfPost` (returns the record). For `Widget`: `FeaturedPost` (`strict_loads?: false`, wraps the loaded `post` in a union). For `Project`: `ProjectSummary` (a fixed `ProjectStats`), `ProjectReport` (two `ProjectMeta` rows, `total: 2`), `SelfRecords`, `IsLate` and `DaysLeft` (module calcs over `due_date`, so ETS needs no date functions) |
| `changes.ex` | `Changes.Metadata` (the metadata values every `*_with_metadata` action sets), the read preparation and change that put them, and `MergeData` for `merge_post_data` |
| `widget.ex` | `AshRpc.Test.Widget`: union theme. `content` (`:type_and_value`; embedded `text`/`checklist` members tagged by `content_type`, scalar `note`/`priority_value`), `status` (`:map_with_tag`, untyped `simple`/`detailed` maps tagged by `status_type`), `attachments` (array of tagged typed-map `file`/`image` members and a string `url`), `belongs_to :post`, `featured` calc (`WidgetItem`). Rows `create_widget`, `list_widgets`, `get_widget` |
| `text_block.ex` | `AshRpc.Test.TextBlock`: embedded `content` member (`text`, `word_count`, `content_type`) with a `display_text` calc |
| `checklist_block.ex` | `AshRpc.Test.ChecklistBlock`: embedded `content` member (`title`, typed-map `items` array, `is_active?` → `isActive`) with a `total_items` calc |
| `widget_item.ex` | `AshRpc.Test.WidgetItem`: `Ash.Type.NewType` union with one `:struct` member (`post`, `instance_of: Post`) |
| `place.ex` | `AshRpc.Test.Place`: keyword `options` and tuple `coordinates` with `fields`, `location` (`GeoPoint`), generic actions returning a keyword (`keyword_options`) and a tuple (`coordinates_info`). Rows `create_place`, `list_places`, `get_place`, `place_keyword_options`, `place_coordinates_info` |
| `geo_point.ex` | `AshRpc.Test.GeoPoint`: tuple NewType (`lat_1`, `lng_1`, `is_verified?` → `lat1`, `lng1`, `isVerified` via `type_field_names/1`); also used by `Intake.location` |
| `project.ex` | `AshRpc.Test.Project`: embedded `metadata` and `history` (array), custom `palette`, custom `trail`/`strict_trail` (`Trail`), `due_date`/`started_at`/atom `priority`, `:duration` `estimate` and `{:array, :duration}` `breaks`, TypedStruct `stats`, `has_many :notes`; calcs `summary`, `report` (typed map with embedded rows), `self` (arg `prefix`), `is_late`, `days_left`; `first` aggregates `first_note_meta` and `first_note_author_info`; generic `process_meta` and `process_meta_batch` taking embedded arguments. Rows `create_project`, `update_project`, `list_projects`, `get_project`, `process_project_meta`, `process_project_meta_batch` |
| `project_note.ex` | `AshRpc.Test.ProjectNote`: has_many target of `Project` with embedded `meta` and a tagged union `author_info` (`meta` member tagged by `info_type`, string `anonymous`). Row `create_project_note` |
| `project_meta.ex` | `AshRpc.Test.ProjectMeta` (embedded: `category`, `priority_score`, `is_urgent`, `deadline`, atom `status`, nested `detail`, `info_type` tag, non-public `internal_notes` its actions still accept; calcs `display_category` and `adjusted_priority` with required arg `multiplier`) and `AshRpc.Test.ProjectMetaDetail` (`note`, `level`) |
| `project_stats.ex` | `AshRpc.Test.ProjectStats`: `Ash.TypedStruct` with a nested typed-map `metrics` field; `all_done?` → `allDone` |
| `trail.ex` | `AshRpc.Test.Trail`: hand-rolled `use Ash.Type` stored as `{:array, :string}`; casts a dotted string or a list of labels, and `strict?: true` rejects a string with a message |
| `missing_post_reactor.ex` | `AshRpc.Test.MissingPostReactor`: a Reactor whose one step fails with `NotFound`, so `Catalog.find_post_via_reactor` returns an error class wrapping a `RunStepError` |
| `palette.ex` | `AshRpc.Test.Palette`: hand-rolled `use Ash.Type` with map storage (`primary`, `secondary`), which the runtime must treat as a primitive |
| `catalog.ex` | `AshRpc.Test.Catalog`: generic actions only (ETS and a read exist for the data layer). Returns `{:array, :struct}` of `Post`, `{:array, :uuid}`, `TaskStats` and an array of it, `{:array, PostStats}`, unconstrained `{:array, :map}`, `:date`, `{:array, :date}`, a typed-map `digest`; struct arguments (`assign`, `assign_many`, `instance_of: Author`); `find_post_via_reactor`, run by `MissingPostReactor`. Rows `catalog_<action>` |
| `task_stats.ex` | `AshRpc.Test.TaskStats`: `Ash.TypedStruct`; `completed?` → `completed`, `is_urgent?` → `isUrgent` |
| `intake.ex` | `AshRpc.Test.Intake`: input theme, every value shape carrying name overrides (`is_active?` → `isActive`, `version_1` → `version1`; `search` arguments `includeDeleted`, `filterBy1`); typed map, NewType maps, keyword and tuple NewTypes, embedded and nested embedded values, a `:type_and_value` and a `:map_with_tag` union; generic `process_data` with a NewType argument. Rows `create_intake`, `update_intake`, `search_intakes`, `process_intake_data` |
| `intake_types.ex` | `Intake`'s NewTypes with `type_field_names/1` overrides: `IntakeStats` (`last_updated_at` deliberately unmapped), `IntakeDeep` holding `IntakeInner`, keyword `IntakePrefs`, union member `IntakeData`, argument type `IntakeInput` |
| `intake_embedded.ex` | `Intake`'s embedded resources with `field_names/1` overrides: `IntakeProfile` (`bioText1`, `isPublic`), `IntakeSection` (`level1`, nested `profile`), `IntakeStatus` (`isFinal`, the `status` union member) |

## Regression Tests

The `regression:` prefix marks the false-value extraction cases in
`test/unconstrained_map_test.exs` (a `false` under an atom or string key must
survive result extraction). Test names carry no external ticket or advisory
references.
