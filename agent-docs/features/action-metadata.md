<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Action Metadata

Ash actions can declare `metadata` fields that are set on the result
(`Ash.Resource.put_metadata/3`) rather than stored as attributes. ash_rpc lets
the client request them with the `metadataFields` param. Request-time metadata
handling lives in `lib/ash_rpc/pipeline.ex`; the exposure helpers
(`metadata_enabled?/1`, `get_exposed_metadata_fields/2`) are in
`lib/ash_rpc/introspection.ex`. `AshRpc.Request` only carries the resolved
list (`show_metadata`).

Every example below is asserted in `test/action_metadata_test.exs`. The fixture
actions are the `*_with_metadata` actions on `AshRpc.Test.Post`
(`test/support/post.ex`). They set `total_score: 42`, `meta_1: "m1"`,
`is_cached?: true`, a typed-map `breakdown` and an unconstrained-map `extra`
(`AshRpc.Test.Changes.Metadata` in `test/support/changes.ex`).

## Declaring and exposing

Three layers decide what a client can get back:

1. **The Ash action** declares the metadata fields and their types
   (`metadata :total_score, :integer`, …). The type is used to format the value
   (see [Value formatting](#value-formatting)).
2. **`entrypoint.exposed_metadata_fields`** (default `[]`) lists the fields the
   client may request. An empty list turns metadata off for that wire action.
   The pipeline treats this list as final. A mapping source that wants "expose
   everything the action declares unless configured otherwise" can compute it
   with `AshRpc.Introspection.get_exposed_metadata_fields/2`.
3. **`entrypoint.metadata_field_names`** (default `%{}`) maps internal names to
   client names. It is needed for names the formatter can't round-trip, such as
   `meta_1` or `is_cached?`.

The fixture rows in `test/support/manifest_builder.ex`:

```elixir
{"read_posts_with_metadata", AshRpc.Test.Post, :read_with_metadata,
 exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
 metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
{"create_post_with_metadata", AshRpc.Test.Post, :create_with_metadata,
 exposed_metadata_fields: [:total_score, :meta_1, :is_cached?, :breakdown, :extra],
 metadata_field_names: %{meta_1: "meta1", is_cached?: "isCached"}},
```

A mapping source sets the same two fields on the `%AshRpc.Entrypoint{}` it
returns from `entrypoint/1` (see [decoration](decoration.md)).

## Resolving `metadataFields`

`parse_request` resolves the param into `request.show_metadata`
(`resolve_show_metadata/4` in `pipeline.ex`):

- If the entrypoint exposes nothing, the result is `[]`, whatever was requested.
- If the param is a non-empty list, each client name is resolved through the
  reverse of `metadata_field_names` first, then through the input formatter.
  Names that aren't in `exposed_metadata_fields` are dropped without an error.
- If the param is absent (or `[]`): read actions get `[]`, and create, update
  and destroy actions get every exposed field.

## On read actions

Requested fields are merged into each returned record, next to the selected
fields. This works for plain lists, single records and page results
(`%{results: […]}`).

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "read_posts_with_metadata",
  "fields" => ["id", "title"],
  "metadataFields" => ["totalScore", "meta1", "isCached"]
})
#=> %{"success" => true,
#     "data" => [%{"id" => …, "title" => "First",
#                  "totalScore" => 42, "meta1" => "m1", "isCached" => true}, …]}
```

| Behaviour | Test (`describe "read actions"`) |
|---|---|
| Requested fields are merged into each record | "requested metadata fields are merged into each record" |
| Only the requested subset is merged | "only the requested subset of exposed fields is merged" |
| No `metadataFields` param, no metadata | "no metadataFields param merges no metadata" |
| Requested but unexposed fields are dropped silently | "requested fields that are not exposed are silently dropped" |
| An entrypoint exposing nothing drops every requested field | "an entrypoint exposing no metadata drops every requested field" |
| An action without metadata ignores the param, and there's no `metadata` key | "an action without metadata ignores metadataFields" |

## On mutations

Create, update and destroy don't merge metadata into the record. The response
gets a top-level `metadata` key next to `data` instead. Without `metadataFields`,
it holds every exposed field. With `metadataFields`, it holds only those.

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "create_post_with_metadata",
  "input" => %{"title" => "Narrowed"},
  "fields" => ["id"],
  "metadataFields" => ["meta1", "totalScore"]
})
#=> %{"success" => true, "data" => %{"id" => …},
#     "metadata" => %{"meta1" => "m1", "totalScore" => 42}}
```

| Behaviour | Test (`describe "mutation actions"`) |
|---|---|
| Create returns every exposed field under `metadata`; `data` holds only the selected fields | "create returns every exposed field under a top-level metadata key" |
| `metadataFields` narrows the `metadata` object | "metadataFields narrows the mutation metadata object" |
| Update returns `metadata` next to the updated record | "update returns metadata alongside the updated record" |
| Destroy without `fields` returns `data: %{}` plus `metadata` | "destroy without fields returns empty data and the metadata" |
| No `metadata` key when the entrypoint exposes nothing | "no metadata key when the entrypoint exposes none" |

A mutation with no field selection and no metadata to show returns `data: %{}`
straight away (`process_result/2`).

## Names

Output always uses the mapped client name from `metadata_field_names`
(`meta1`, `isCached`). Fields without a mapping go through the output formatter
(`total_score` → `totalScore`). Requests also accept the original internal names
(`"meta_1"`, `"is_cached?"`), but the output keys stay mapped.
Test: `describe "metadata field names"`, "original names are accepted in
requests but output stays mapped".

## Value formatting

Each value is formatted with `AshRpc.ValueFormatter` against the metadata
field's declared type (`format_metadata/2` in `pipeline.ex`), the same
type-driven dispatch used for attributes (see [formatting](formatting.md)).
`format_output` then formats only the top-level keys of the `metadata` object,
since the values are already formatted.

| Behaviour | Test (`describe "metadata value formatting"`) |
|---|---|
| A typed map (`breakdown`, `:map` with `fields`) gets its nested keys formatted: `%{"topScore" => 9, "tagNames" => ["a", "b"]}` | "typed-map metadata has its nested keys formatted" |
| An unconstrained map (`extra`) passes through verbatim, keeping keys like `"_id"` and `"snake_key"` | "unconstrained-map metadata passes through verbatim on read", "… on create" |

## Related

- [pipeline](pipeline.md): where `parse_request` and `process_result` sit
- [troubleshooting](../troubleshooting.md): metadata missing from a response
