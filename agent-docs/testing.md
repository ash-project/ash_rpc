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
| [field selection](features/field-selection.md) | `test/field_selector_test.exs`, `test/typed_field_selection_test.exs`, `test/calculations_test.exs`, `test/aggregates_test.exs`, `test/nested_query_opts_test.exs`, `test/load_restrictions_test.exs`, `test/result_output_test.exs`, `test/result_processor_test.exs`, `test/type_classification_test.exs` |
| [formatting](features/formatting.md) | `test/value_formatter_test.exs`, `test/field_formatter_test.exs`, `test/field_name_translation_test.exs`, `test/union_input_test.exs`, `test/unconstrained_map_test.exs` |
| [action metadata](features/action-metadata.md) | `test/action_metadata_test.exs` |
| [errors](features/errors.md) | `test/errors_test.exs`, `test/error_protocol_test.exs`, `test/error_builder_golden_test.exs` |

Two files belong to no feature doc:

- `test/fixtures_test.exs`: smoke tests for the fixtures themselves (ETS
  persistence, the generator seeing the fixture domain, row opts reaching
  `%AshRpc.Entrypoint{}`, an unknown row opt failing the build).
- `test/introspection_test.exs`: `AshRpc.Introspection` helpers (pagination
  predicates, return classification, metadata helpers, `ash_resource?/1`).

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
| `domain.ex` | `AshRpc.Test.Domain`: the nine fixture resources (embedded types are not listed) |
| `mapping_source.ex` | `AshRpc.Test.MappingSource`: `@exposed` list, overrides (`Author` `isActive`/`isProlific`, `word_count` argument `text` → `body`, `PostStats` `wordCount1`/`isFeatured`), row opts → `%AshRpc.Entrypoint{}` via `struct!/2` |
| `manifest_builder.ex` | `AshRpc.Test.ManifestBuilder`: `@entrypoints` wire rows; `manifest/0`, `build/1`, `generate!/1` |
| `profile.ex` | `AshRpc.Test.Profile`: `use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder`, all callbacks default |
| `endpoint.ex` | `AshRpc.Test.Socket`, `AshRpc.Test.Endpoint`, and `AshRpc.Test.RpcChannel` (`use AshRpc.Channel`, joins `"rpc:*"`) |
| `error_cases.ex` | `AshRpc.Test.ErrorCases`: one reason per `ErrorBuilder` clause, for the golden test |
| `post.ex` | `AshRpc.Test.Post`: the main resource. Typed-map `stats`, embedded `settings`, unconstrained `data`, `unique_slug` identity; relationships to `author`, unexposed `secret`, `comments` (plus offset-only/keyset-only variants), `tags`; calculations with and without args; aggregates; metadata actions; generic actions returning `:map`, typed map, tuple, union and nothing |
| `author.ex` | `AshRpc.Test.Author`: `is_active?` / `is_prolific?` (name overrides), `post_count` aggregate, `name_active` identity, actor-scoped `me` / `update_me` / `destroy_me` |
| `comment.ex` | `AshRpc.Test.Comment`: has_many target. Union `attachment` (embedded `file` / string `note`), `weighted_rating` calc, reads with offset+keyset, offset-only, keyset-only and a `rated` read filtered by a `min_rating` argument |
| `comment_attachment.ex` | `AshRpc.Test.CommentAttachment`: embedded union member with a `label` calculation |
| `tag.ex` | `AshRpc.Test.Tag`: many_to_many target with a paginated read |
| `post_tag.ex` | `AshRpc.Test.PostTag`: join resource for `Post.tags` |
| `note.ex` | `AshRpc.Test.Note`: attribute multitenancy (`workspace_id`), has_many `replies` |
| `note_reply.ex` | `AshRpc.Test.NoteReply`: multitenant child of `Note` with a paginated read |
| `ledger.ex` | `AshRpc.Test.Ledger`: union `count` and arrays allowing nil items; `count` deliberately collides with the page-map key (`page_ledgers`) |
| `secret.ex` | `AshRpc.Test.Secret`: in the domain but deliberately **not exposed**, for strict-exposure tests |
| `post_settings.ex` | `AshRpc.Test.PostSettings`: embedded resource with a `theme_label` calculation |
| `post_stats.ex` | `AshRpc.Test.PostStats`: `Ash.Type.NewType` map with fields `word_count_1` and `is_featured?` (client names via `type_field_names/1`) |
| `calculations.ex` | Module calculations for `Post`: `Excerpt` (arg `length`), `ScoredStats` (arg `boost`, returns `PostStats`), `SelfPost` (returns the record) |
| `changes.ex` | `Changes.Metadata` (the metadata values every `*_with_metadata` action sets), the read preparation and change that put them, and `MergeData` for `merge_post_data` |

## Regression Tests

The `regression:` prefix marks the false-value extraction cases in
`test/unconstrained_map_test.exs` (a `false` under an atom or string key must
survive result extraction). Test names carry no external ticket or advisory
references.
