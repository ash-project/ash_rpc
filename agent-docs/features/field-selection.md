<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Field Selection

How the `fields` param becomes an Ash `select`/`load` and an extraction
template, and how the result is cut back down to what the client asked for.
Examples use the `AshRpc.Test.*` fixtures and the wire names in
`test/support/manifest_builder.ex`.

## Entry Point

Field processing runs inside `parse_request` (see [pipeline](pipeline.md)).
`AshRpc.RequestedFieldsProcessor` is a delegator:

```elixir
runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)

{:ok, {select, load, template}} =
  AshRpc.RequestedFieldsProcessor.process(runtime, AshRpc.Test.Post, :read, [:id, %{author: [:name]}])

# select   => [:id]                         attributes to select
# load     => [author: [:name]]             relationships/calculations/aggregates to load
# template => [:id, {:author, [:name]}]     extraction template for ResultProcessor
```

`process(runtime, resource, action_name, requested_fields, opts \\ [])` returns
`{:ok, {select, load, template}}` or `{:error, reason}`. Every selection error
is thrown inside `FieldSelector` and caught by `FieldSelector.process/5`, so it
reaches the client as an `ErrorBuilder` error (see [errors](errors.md)). The
pipeline passes the entrypoint's `enable_filter?`, `enable_sort?` and
normalized `load_restrictions` as `opts`; they default to `true`, `true` and
`:none`.

Flow:

1. **Atomizer** (`lib/ash_rpc/field_processing/atomizer.ex`). At each resource
   level, client names that match a field-name override become internal atoms
   (`"isActive"` → `:is_active?` on `AshRpc.Test.Author`). Nested selections are
   left as sent and translated when selection recurses into the destination
   type. Names without an override stay strings and are resolved through the
   input formatter. `atomize_requested_fields/3` is public for callers that
   pre-process selections; the pipeline doesn't call it.
2. **FieldSelector** (`lib/ash_rpc/field_processing/field_selector.ex`).
   Type-driven recursion on `AshRpc.Introspection.classify_type/2`, the same
   dispatch `ValueFormatter` and `ResultProcessor` use (see
   [formatting](formatting.md)). The selection is applied to the action's return
   type: an array of the resource for a list read, the resource for a get or a
   mutation, `action.returns` for a generic action.

   | `classify_type/2` result | Handler |
   |---|---|
   | `{:array, item}` | recurse into the item type |
   | `{:resource, mod}` (resource or embedded resource) | `select_resource_fields/4` |
   | `{:union, type}` | `select_union_fields/5` |
   | `{:typed_struct, type}` (a type with field-name overrides) | `select_typed_struct_fields/4` |
   | `{:fields, type}` tuple | `select_tuple_fields/4` |
   | `{:fields, type}` map/keyword/struct with `fields` constraints | `select_typed_map_fields/5` |
   | `{:other, %{kind: :any}}` (generic action without a typed return) | names passed through to the template |
   | anything else | primitive: any nested selection is `invalid_field_selection` |

   `:type_ref` types are resolved through `runtime.type_lookup` before
   dispatch. Resource fields are looked up in the manifest resource's `fields`
   map (attributes, calculations and aggregates share it), then in
   `relationships`; no match is `unknown_field`.
3. **ResultProcessor** (`lib/ash_rpc/result_processor.ex`). `process/4` walks
   the Ash result against the template in one pass, using the same type
   dispatch. Pages (`%Ash.Page.Offset{}` / `%Ash.Page.Keyset{}`) go through
   `build_page_map/2`, for top-level and nested pagination alike.
   `AshRpc.FieldExtractor` does the per-record key access.

## Unified Field Format

Everything goes in one `fields` list. Nested selections are maps.

```elixir
[
  "id",
  "titleLength",                                          # calculation without arguments
  %{"author" => ["name", "isProlific"]},                  # relationship + nested calculation
  %{"excerpt" => %{"args" => %{"length" => 5}}},          # scalar calculation with arguments
  %{"scoredStats" => %{"args" => %{"boost" => 2}, "fields" => ["wordCount1"]}}
]
```

Only `args` and `fields` are recognized inside a calculation map. A map that
also has `page`, `filter`, `sort`, `limit` or `offset` is a
[query envelope](#nested-relationship-query-options).

Calculations fall into three categories (`get_resource_field_info_from_spec/5`):

| Category | When | Syntax |
|---|---|---|
| `:calculation` | No arguments, primitive return | `"titleLength"` |
| `:calculation_complex` | No arguments, return needs a selection (resource, embedded, union, typed map) | `%{"selfPost" => ["title", %{"author" => ["name"]}]}` |
| `:calculation_with_args` | Declares any argument (even with defaults) | `%{"calc" => %{"args" => %{…}}}`, plus `"fields"` when the return needs a selection |

Asserted in `test/calculations_test.exs`:

- "a calculation without arguments is selected by name": `["id", "titleLength"]` → `%{"id" => …, "titleLength" => 11}`.
- "a scalar calculation with arguments takes args only": `%{"excerpt" => %{"args" => %{"length" => 5}}}` → `%{"excerpt" => "Hello"}`.
- "a typed-map calculation takes args and fields; unselected keys are absent": `Post.scored_stats(boost:)` returns `AshRpc.Test.PostStats`; selecting `["wordCount1"]` gives `%{"scoredStats" => %{"wordCount1" => 5}}` with no `isFeatured` key.
- "a resource-returning calculation nests relationships": `Post.self_post` loads through (`{:self_post, {%{}, [:title, author: [:name]]}}`).
- "calculations mix with attributes, relationships and nested calculations".

## Selection Errors

| Wire `type` | Cause | Test |
|---|---|---|
| `requires_field_selection` | A relationship, embedded resource, union, typed value or complex calculation requested by bare name, or with missing/empty `fields` | calculations_test "a complex calculation requested as a bare name", "a complex calculation with args but missing or empty fields" |
| `invalid_calculation_args` | `args` on a calculation that takes none, or a calculation with arguments sent without `args` | calculations_test "args on a calculation that takes none", "missing args on a calculation that takes arguments" |
| `invalid_field_format` | A calculation with arguments requested as a bare name (internal reason `calculation_requires_args`) | calculations_test "calculation_requires_args: a calculation with arguments requested as a bare name" |
| `invalid_field_selection` | A `fields` key on a scalar calculation, or a nested selection on a primitive aggregate | calculations_test "invalid_field_selection: a fields key on a scalar calculation"; aggregates_test "nested selection on a primitive aggregate is invalid_field_selection" |
| `field_does_not_support_nesting` | A nested list on a scalar calculation or attribute | calculations_test "field_does_not_support_nesting: nested fields on a scalar calculation" |
| `unknown_field` | No such field on the resource or in a nested selection (`path` names the parent) | calculations_test "an unknown calculation name", "an unknown field inside a calculation's selection"; aggregates_test "an unknown aggregate is unknown_field, bare or with nested fields" |
| `unknown_map_field` | Unknown key in a typed map without field-name overrides | calculations_test "unknown_map_field: an unknown key in a typed-map return" |
| `duplicate_field` | The same name twice at one level (names are normalized through the input formatter first) | calculations_test "duplicate_field: the same calculation requested twice with different args" |

An unknown key inside a typed struct (a type with field-name overrides, such
as `PostStats`) is `unknown_field` with `vars.kind` `"field constrained"`.

## Aggregates

Aggregates are selected by name (`"commentCount"`, `"hasComments"`,
`"avgRating"`, `"firstCommentBody"`, `"commentBodies"`, …) and always count as
loads. A nested selection on an aggregate with a primitive return is
`invalid_field_selection` (`vars.fieldType` `":aggregate"`). Aggregates appear
in mutation results too, and the client can sort and filter by them. See
`test/aggregates_test.exs`: "each Post aggregate is computed over its
comments", "Author.post_count counts the author's posts", "create returns
empty-aggregate values for a new post", "update returns aggregates reflecting
existing comments", and the "sort and filter by aggregates" describe.

## Nested Relationship Query Options

A has_many or many_to_many relationship accepts an envelope instead of a plain
field list:

```elixir
%{"comments" => %{
  "page" => %{"limit" => 2, "offset" => 0, "count" => true},
  "filter" => %{"rating" => %{"greaterThan" => 2}},
  "sort" => "-rating",
  "fields" => ["id", "body"]
}}
```

`validate_query_opts!/7` checks, in order:

1. the field is a relationship (otherwise `invalid_query_opts`, or `unknown_field` if there is no such field);
2. it is to-many (otherwise `invalid_query_opts`);
3. the destination is exposed (otherwise `unknown_field`);
4. no `args` key (otherwise `invalid_query_opts`);
5. `page` only if the relationship's read action paginates (decorated as `Custom.relationship_pagination/1`; otherwise `pagination_not_supported`);
6. `filter`: the entrypoint's `enable_filter?`, then the relationship's `filterable?` (otherwise `filter_not_supported` with `details.reason` `disabled` / `unsupported`);
7. `sort`: `enable_sort?`, then `sortable?` (`sort_not_supported`, same reasons);
8. `page` is not mixed with bare `limit`/`offset` (otherwise `invalid_query_opts`);
9. `fields` is non-empty (otherwise `requires_field_selection`).

An unknown key inside a nested `page` is `invalid_pagination`. Allowed page
keys are `limit`, `offset`, `count` for offset pagination and `limit`, `after`,
`before`, `count` for keyset pagination.

The load becomes `{rel, %Ash.Query{}}` built with
`Ash.Query.for_read(Custom.relationship_read_action(rel))` plus
`filter_input`, `sort_input`, `page`, `limit`, `offset` and the nested
select/load. The extraction template is the same as for a plain nested list.

Behaviour, all asserted in `test/nested_query_opts_test.exs`:

- With `page`, the relationship value is the top-level page shape: offset pages
  have `count`, `hasMore`, `limit`, `offset`, `results`, `type`; keyset pages
  have `after`, `before`, `count`, `hasMore`, `limit`, `nextPage`,
  `previousPage`, `results`, `type` and no `offset` ("a paged has_many returns
  the top-level offset page shape", "a keyset-only relationship returns the
  keyset page shape with cursors").
- An empty keyset page has nil cursors ("an empty keyset page past the last
  cursor has nil cursors").
- An offset-only relationship (`Post.comments_offset`) pages with its own read
  action ("an offset-only relationship pages with its own read action").
- An envelope without `page` keeps the plain array ("filter, sort and limit
  without page keep the plain array shape"), and works on a create result.
- many_to_many works through the join resource (`Post.tags` via
  `AshRpc.Test.PostTag`; the "many_to_many envelopes" describe).
- Nested filter and sort obey the entrypoint flags: `list_posts_no_filter` /
  `list_posts_no_sort` give `disabled` (the "entrypoint flags gate nested
  envelopes" describe).

Top-level `filter`, `sort` and `page` are validated in `parse_request`, not
here; see [pipeline](pipeline.md).

## Strictness and Exposure

- Every requested name must resolve. There is no silent drop: unknown names are
  `unknown_field` / `unknown_map_field`, duplicates are `duplicate_field`, and
  anything that needs a selection and doesn't get one is
  `requires_field_selection`.
- Strict exposure: selecting through a relationship whose destination the
  mapping source doesn't expose is `unknown_field`, both for plain nested lists
  and for envelopes. `Post.secret` points at `AshRpc.Test.Secret`, which is
  deliberately left out of `@exposed` in `test/support/mapping_source.ex`
  (`test/field_selector_test.exs` "a relationship to an unexposed resource is
  unknown_field").

## Embedded Resources and Typed Values

Embedded resources go through the same resource branch as regular resources,
with the same syntax as relationships. Attributes go to `select` and the
embedded resource's calculations to `load`. For
`%{"settings" => ["themeName", "themeLabel"]}` on `Post.settings`
(`AshRpc.Test.PostSettings`, with the `theme_label` calculation), the load is
`[{:settings, [:theme_label]}]` (`test/load_restrictions_test.exs` "an
embedded resource calculation is a load"), and the wire result is
`%{"settings" => %{"themeName" => "dark", "themeLabel" => "theme:dark"}}`
(`test/typed_field_selection_test.exs` "nested fields select attributes and
load calculations"). A bare `"settings"` is `requires_field_selection` with
`vars.fieldType` `Embedded_resource` ("a bare embedded field is
requires_field_selection").

Typed values need an explicit selection:

- Typed struct: a type with field-name overrides. `AshRpc.Test.PostStats`
  exposes `word_count_1` / `is_featured?` as `wordCount1` / `isFeatured`, so
  `"fields" => ["wordCount1"]` on the `stats_summary` action returns
  `%{"wordCount1" => 3}`.
- Typed map without overrides (the `totals` action) and tuple (`location`) use
  field names resolved through the input formatter.
- Templates key nested typed fields by internal name (the `payload` union's
  `stats` member → `[stats: [:word_count_1]]`; tuple `location` → `[lat: []]`).
- An empty selection on a typed return is `requires_field_selection` from
  `RequestedFieldsProcessor.process/5`: pathless at the top level, naming the
  field when nested (`[%{"byKind" => []}]`). On the wire a top-level
  `"fields" => []` is caught earlier as `empty_fields_array`, and a missing
  `fields` is `missing_required_parameter`.
- Query options on a typed struct, typed map, tuple or union field are
  `invalid_query_opts`, never a crash.

See `test/typed_field_selection_test.exs`: "sanity: typed returns select
fields", the "query options on typed fields are rejected, not crashed on" and
"requires_field_selection on typed values" describes.

## Union Output Selection

Select union members by name. A member whose value is a resource or typed value
takes a nested list:

```elixir
# Ledger.count is a union of number: :integer and label: :string
%{"count" => ["number", "label"]}           # => %{"count" => %{"number" => 3}}
%{"stats" => ["wordCount1"]}                # payload action: member with nested fields
```

- A bare union field (`"count"`) is `requires_field_selection`
  (`test/union_input_test.exs` "output selection must name members").
- `ResultProcessor.extract_union_value/4` returns `%{member => value}` for the
  active member, and `nil` when the active member wasn't requested. In arrays,
  items whose member wasn't requested are dropped and items that were `nil` are
  kept (`test/result_output_test.exs` "array items whose union member wasn't
  requested are dropped, nil items kept").
- Union member calculations are loads, so load restrictions apply to them.

Union *input* (the wrapped `%{"member" => value}` format) is in
[formatting](formatting.md).

## Unconstrained Map Output

A `:map` without `fields` constraints is opaque:

- A generic action whose return classifies as `:unconstrained_map` /
  `:array_of_unconstrained_map` (`Introspection.return_classification/2`)
  needs no `fields` param. Its result is returned verbatim: keys untouched
  (snake_case, camelCase and nested keys alike), no extraction, and no output
  formatting (`test/unconstrained_map_test.exs` "returns the payload verbatim
  without a fields selection", on `echo_map`).
- An unconstrained map attribute (`Post.data`) is selected by bare name and
  comes back the same way ("create round-trips the map verbatim, snake_case and
  nested keys untouched").
- `false` values survive extraction against a field template under atom or
  string keys (the `regression:` cases in the "ResultProcessor.extract_value/5
  on plain maps with a field template" describe).

## Load Restrictions

`entrypoint.load_restrictions` is `:none`, `{:allow, tree}` or
`{:deny, tree}` (see [decoration](decoration.md)). Allow and deny are mutually
exclusive by construction: it is a single tagged tuple. Trees use keyword
syntax: `[:author]`, `[comments: [:post]]`.

- `AshRpc.LoadRestrictions.normalize/1` runs once in `parse_request` and turns
  the tree into path lists (`[comments: [:post]]` → `[[:comments, :post]]`).
- `FieldSelector` calls `LoadRestrictions.check!/2` with `path ++ [name]` at
  every point where it appends to the load statement: simple calculation or
  aggregate, nested relationship, nested or complex calculation, calculation
  with args, query envelope, and embedded or union attributes that carry nested
  loads. A load can't reach Ash without being checked, and there is no second
  traversal.
- The first offending path fails the request.

Fixture entrypoints (`manifest_builder.ex`): `list_posts_allow_author`
(`{:allow, [:author]}`), `list_posts_allow_nested`
(`{:allow, [comments: [:post]]}`), `list_posts_allow_nested_calc`,
`list_posts_deny_author`, `list_posts_deny_nested`,
`list_posts_deny_nested_calc`, `list_comments_allow_post` and
`list_comments_keyset_allow_post` (`{:allow, [:post]}` on `Comment`'s `:read`
and `:keyset_only`).

Rules, all in `test/load_restrictions_test.exs`:

- Calculations and aggregates count as loads ("top-level calculations and
  aggregates count as loads"). Plain attributes never do; an embedded or union
  attribute counts only when its selection carries nested loads.
- Allow: intermediate relationships of an allowed nested path are allowed ("an
  intermediate relationship of an allowed nested path loads"), but children of
  an allowed relationship are not ("a child of an allowed relationship is not
  implicitly allowed").
- Deny: children of a denied relationship are denied ("children of a denied
  relationship are denied"), and a nested deny leaves the parent loadable ("a
  nested deny leaves the parent loadable").
- Restrictions apply inside query envelopes, offset and keyset pages,
  `count: true`, embedded resource calculations and union member calculations
  (the "query envelopes", "pagination" and "nested calculations" describes).

Wire errors: `load_not_allowed` with `details.disallowedPaths`, and
`load_denied` with `details.deniedPaths`. Paths are dotted internal names
(`"comments.weighted_rating"`, `"settings.theme_label"`), not client names.
From "load_not_allowed carries the disallowed paths":

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "list_posts_allow_author",
  "fields" => ["id", %{"comments" => ["id"]}]
})
# errors: [%{
#   "type" => "load_not_allowed",
#   "shortMessage" => "Load not allowed",
#   "fields" => ["comments"],
#   "path" => [],
#   "vars" => %{"fields" => "comments"},
#   "details" => %{"disallowedPaths" => ["comments"]}
# }]
```

Load restrictions shape an entrypoint's surface (typically to keep expensive
loads off endpoints that don't need them). They are **not** authorization: Ash
policies still run on every load.
