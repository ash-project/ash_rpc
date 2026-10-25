<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Value and Input Formatting

How values and keys cross the wire boundary in both directions: client keys
become internal atoms on the way in, and internal names become client names on
the way out. Field *selection* (which keys appear at all) is covered in
[field-selection.md](field-selection.md). Where the client names come from
(mapping source, overrides, formatters fixed at decoration) is covered in
[decoration.md](decoration.md).

## `AshRpc.ValueFormatter`

```elixir
AshRpc.ValueFormatter.format(value, type, constraints, :input | :output, runtime)
```

- `type` is an `%Ash.Info.Manifest.Type{}`, `%Ash.Info.Manifest.Field{}`,
  `%Ash.Info.Manifest.Relationship{}`, a raw Ash type (atom or `{:array, inner}`,
  resolved through `Ash.Info.Manifest.Generator.TypeResolver.resolve/2`), or
  `nil` (value returned unchanged).
- `constraints` only matter for raw Ash types; manifest structs carry their own.
- `runtime` is an `%AshRpc.Runtime{}`. `:output` names with
  `runtime.output_formatter`; `:input` resolves names by exact lookup with
  `AshRpc.ClientNames` and never calls a formatter. A nested key that isn't a
  client name stays the client's string, for Ash to cast or reject. Overrides
  and lookups come from the runtime, never from app config
  (`test/value_formatter_test.exs` "runtime formatter is used, not config").

**Design.** Every composite value is a value plus its resolved manifest type,
and each type is self-describing, so no "parent resource" is threaded through.
Dispatch goes through `AshRpc.Introspection.classify_type/2`, the same
classification `AshRpc.FieldProcessing.FieldSelector` and `AshRpc.ResultProcessor`
use, so selection, extraction and formatting recurse the same way.

### Type categories

| `classify_type/2` result | Covers | Keys come from |
|---|---|---|
| `{:array, item_type}` | `kind: :array` | Each element formatted with `item_type`; a non-list value passes through |
| `{:resource, module}` | Resources, embedded resources, and `:struct`/`:map` types whose effective module is an Ash resource | Input: `AshRpc.ClientNames.resource_field/3`. Output: `FieldFormatter.format_field_for_client/3`; a string key (a read action's metadata override) goes out as-is. Each value recurses with the manifest field or relationship type |
| `{:union, type}` | `kind: :union` | Member-specific; see [Union input](#union-input) |
| `{:typed_struct, type}` | `:struct`/`:map`/`:tuple`/`:keyword` with type field-name overrides | Input: `AshRpc.ClientNames.type_field/3`. Output: [declared fields only](#declared-only-output), named by the type's `custom.ash_rpc` override pair, falling back to `AshRpc.Introspection.type_field_name_overrides/2` (type lookup, then the mapping source's `type_field_names/1`, which a declared custom type never consults) |
| `{:fields, type}` | `:struct`/`:map`/`:tuple`/`:keyword` without overrides | Input: `AshRpc.ClientNames.type_field/3`. Output: [declared fields only](#declared-only-output), named by decoration. A type with no `fields` (an unconstrained map) passes through untouched |
| `{:other, type}` | Everything else | Scalars pass through, except `Ash.Type.Vector` (packed binary → list of floats). A custom type still `kind: :unknown` at runtime isn't map-like (decoration rejects undeclared map-like types on the wire), so its value passes through as produced (after `normalize_primitive/2` on extraction paths). A custom type with declared fields is a `:type_ref` to a typed map instead (see [decoration](decoration.md#declared-custom-types)) |

Also handled before classification:

- `%Ash.Info.Manifest.Field{}` unwraps to its `type`.
- `%Ash.Info.Manifest.Relationship{}`: `cardinality: :many` maps over the list,
  otherwise one record is formatted against `destination`. A nested page map
  (`type: :offset | :keyset`, output only) has its keys formatted and only
  `results` formatted as records.

Handled during or after classification:

- `kind: :type_ref` is resolved inside `classify_type/2` (type lookup, then the
  module) and classified as the named type.
- Tuples and keyword lists match on `kind: :tuple | :keyword` after
  classification, become maps keyed by field name, then go through
  typed-struct or typed-map formatting.
- `:map_with_tag` union output renames a tag field the member type doesn't
  declare under the formatter's name before the member is formatted. An
  untyped (unconstrained map) member keeps it; a typed-map member drops it,
  as extraction already does, since the tag isn't one of its declared fields.

### Declared-only output

On output, a typed struct, typed map, keyword or tuple emits only the value's
entries whose key is a declared field: the field's atom name, or its string
form. Each kept value is formatted with that field's type, and everything else
is dropped. Undeclared keys never reach a client, and a client-cased string key
(`"themeName"`) is not a declared field either. A struct value goes through
`Map.from_struct/1` first, so it no longer raises. The output doesn't add
declared fields the value lacks: an extracted value carries only the selected
fields, and the others don't appear as `nil`.

This holds on every output path, including those that format without
extraction: action metadata, unselected union members, and values an
extension formats itself with `format/5` (typed route results, channel
payloads). Names come from decoration: the type's override pair (or
`AshRpc.Introspection.type_field_name_overrides/2`), then
`AshRpc.Manifest.Custom.type_field_names/1` of the node or its type-lookup
entry. Only a container no decoration reached (a type missing from the type
lookup) falls back to the formatter, and it runs over the declared field's
name, never over a value key. Asserted by `test/declared_output_test.exs`.

### Deep nesting example

`AshRpc.Test.Post` has a `stats` attribute of type `AshRpc.Test.PostStats`
(typed map, overrides `word_count_1 → "wordCount1"`, `is_featured? → "isFeatured"`),
an embedded `settings` (`AshRpc.Test.PostSettings`), and an unconstrained
`data` map. With the test profile's camelCase formatters:

```elixir
runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)

AshRpc.ValueFormatter.format(
  %{view_count: 1,
    stats: %{word_count_1: 3, is_featured?: true},
    settings: %{theme_name: "dark"},
    data: %{"snake_key" => 1}},
  AshRpc.Test.Post, [], :output, runtime)
# => %{"viewCount" => 1,
#      "stats" => %{"wordCount1" => 3, "isFeatured" => true},   # type overrides
#      "settings" => %{"themeName" => "dark"},                  # embedded resource
#      "data" => %{"snake_key" => 1}}                            # unconstrained: untouched
```

The `:input` direction reverses every step (`"wordCount1" → :word_count_1`,
`"themeName" → :theme_name`, `"data"` contents untouched). The parts are asserted
by `test/value_formatter_test.exs` ("output: mapped NewType fields use decorated
overrides", "input: reverse overrides map client keys back", "runtime formatter is
used, not config") and `test/unconstrained_map_test.exs`. On the wire, the same
`PostStats` overrides apply to the `Post.scored_stats` calculation:
`%{"scoredStats" => %{"args" => %{"boost" => 2}, "fields" => ["wordCount1"]}}`
returns `%{"scoredStats" => %{"wordCount1" => 5}}`
(`test/calculations_test.exs` "a typed-map calculation takes args and fields; unselected keys are absent").

### Where it runs in the pipeline

- **`parse_request`** (input): `AshRpc.InputFormatter.format/4` formats
  `params["input"]`; a key that isn't a client name, top-level or nested, is
  `unknown_input` before Ash runs. The other top-level param
  keys resolve through the `:params` vocabulary (a miss is dropped), `filter`
  and `sort` through `AshRpc.FilterInput`, `page` keys through the `:page`
  vocabulary and `getBy`/`identity` keys through `ClientNames.resource_field/3`.
  `input` and `identity` are popped first and matched literally.
- **`format_output`** (output): `AshRpc.Pipeline` calls `ValueFormatter.format/5`
  directly (there is no output-formatter module). Non-generic actions are
  formatted against the resource; generic actions use the classification of
  `action.returns`, and an untyped return (an unconstrained map or
  `Ash.Type.Term`) is passed through as-is.

See [pipeline.md](pipeline.md) for the stages themselves.

### `format_input/3`: one typed value, errors returned

```elixir
AshRpc.ValueFormatter.format_input(value, %Ash.Info.Manifest.Type{} = type, runtime)
# => {:ok, formatted} | {:error, reasons}
```

For a consumer formatting a single typed value outside an action input (for
example an extension's own endpoint argument) with the same strict rules RPC
applies to `params["input"]`. The pipeline doesn't call it, and `format/5` is
unchanged.

- Client names resolve by exact lookup, and every key of a node with decorated
  names must be one of them. Undecorated nodes and unconstrained maps keep their
  keys as sent.
- `reasons` is every `{:unknown_input, key, path}` miss, in input order, with
  `path` relative to `value`: `[]` for a key directly in it, `["history", 1]`
  deeper. Unlike `InputFormatter`, there is no top-level action key to prepend.
- A malformed union value returns its `:invalid_union_input` reason (for example
  `{:error, [{:invalid_union_input, :not_a_map}]}`) instead of throwing. The
  function never throws; `{:unknown_nested_input, …}` stays internal.

Covered by `test/value_formatter_test.exs` `describe "format_input/3"`.

## Input formatting: `AshRpc.InputFormatter`

```elixir
AshRpc.InputFormatter.format(data, resource, action_name_or_action, runtime)
# => {:ok, internal_input} | {:error, reason}
```

- Builds the `%{client_name => internal_name}` map with
  `AshRpc.InputFormatter.expected_keys(action, resource, runtime)`. It reads the
  map precomputed at decoration (`custom.ash_rpc.expected_input_keys`) and
  otherwise computes it. Client input names are formatted with the **output**
  formatter, so a client sends back the same names it receives; accepted
  attributes use the resource's field names and arguments use the action's
  argument overrides.
- Each matched value is formatted with `ValueFormatter.format/5` (`:input`)
  against the input's type (`custom.ash_rpc.input_field_types`, else
  `action.inputs`).
- A key not in the map is `{:unknown_input, key}`. Nested keys are checked by
  `ValueFormatter` against the decorated names of their type (typed maps,
  keywords, tuples, TypedStructs, embedded resources, union member values): a
  miss is `{:unknown_input, key, path}`, with `path` the parent keys as sent
  plus array indexes. Each map level resolves all of its keys and formats every
  value before throwing `{:unknown_nested_input, reasons}`, and each parent
  prepends its key (`ValueFormatter.collect_input/2`), so every miss is
  reported at once (`test/complex_input_test.exs` "strict nested input keys").
  Every embedded resource is decorated (an unexposed one under formatter-only
  names), so its nested keys are strict too. A node with no decorated names
  (`ClientNames.resource_named?/2`, `type_named?/2` false) keeps its keys as
  sent and leaves them to Ash
  (`test/value_formatter_test.exs` "a type that was never decorated keeps its
  keys as sent").
- Non-embedded struct inputs whose type is backed by an Ash resource are cast to
  that resource struct after key formatting. Ash casts everything else itself.
  A map that fails that cast is passed on as formatted, so Ash reports it:
  an empty `assignee` map is one `invalid_argument` per missing struct field,
  with `path` `["assignee"]` (`test/complex_input_test.exs` "an empty map fails
  the struct cast with an invalid_argument per missing field").
- Formatting errors are thrown inside the formatter and come back as
  `{:error, reason}` (for example the union errors below).

Client keys map back to internal names through the reverse overrides
(`test/value_formatter_test.exs` "input: reverse overrides map client keys back").

## Union input

A union input value **must** be wrapped: a map with exactly one key naming the
member, `%{"member_name" => value}`. `AshRpc.Test.Ledger.count` is a union of
`number: :integer` and `label: :string` (wire action `create_ledger`):

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "create_ledger",
  "input" => %{"count" => %{"number" => 3}},
  "fields" => ["id", %{"count" => ["number", "label"]}]
})
# => %{"success" => true, "data" => %{"id" => _, "count" => %{"number" => 3}}}
```

(`test/union_input_test.exs` "a map with one member key selects that member".)
Arrays of unions wrap each element the same way.

**Member identification** (`ValueFormatter`, input direction):

1. **Tag first.** If a member declares `tag` / `tag_value` and the map contains
   that tag key with that value, the member is chosen. The "exactly one member
   key" check does not run on this path. On input the tag is injected back into
   the formatted member value. The tag key is matched with
   `ClientNames.type_field/3`, or `resource_field/3` for an embedded-resource
   member (`test/union_output_test.exs` "tagged member input").
2. **Member key.** Otherwise each map key is looked up with
   `ClientNames.union_member/3` (the union's `client_member_names`). Exactly one
   must match; a non-client casing is not a member
   (`test/union_input_test.exs` "a member key in a non-client casing is not a member").

**`:map_with_tag` output.** The tag key is named by the member type's
decoration, overrides included and used as written, so it matches the
member's other keys: `IntakeStatus` maps `status_type` to `"statusKind"`, and
the output is `"statusKind"` under every formatter. Only a tag field the member
type doesn't declare is named by the output formatter, and only an untyped
member keeps it (see [declared-only output](#declared-only-output))
(`test/complex_input_test.exs` "a :map_with_tag tag key is output under the
member's client name", `test/value_formatter_test.exs` "the tag key uses the
member's decorated name, not re-formatted").

The three errors, all `type: "invalid_union_input"` (`AshRpc.ErrorBuilder`),
asserted end to end by `test/union_input_test.exs`:

| Input | `message` | Extra |
|---|---|---|
| Bare value (`"count" => 3`) | `Union input must be a map with exactly one member key` | `details.suggestion`: `Provide union input in the format: {"member_name": value}` ("a bare value is not_a_map") |
| No member key (`%{"other" => 1}`, or `%{}`) | `Union input map does not contain any valid member key` | `vars.expectedMembers` `"number, label"`, `details.expectedMembers` `["number", "label"]` ("a map without a member key lists the expected members") |
| Several member keys (`%{"number" => 1, "label" => "x"}`) | `Union input map contains multiple member keys: %{foundKeys}` | `vars.foundKeys` and `vars.expectedMembers` `"number, label"` ("a map with several member keys is rejected") |

`message` keeps its `%{…}` placeholder; clients fill it from `vars`. The first
two errors carry the stale-client `details.hint` (a stale client can send them);
the multiple-keys error is classed as a malformed request and carries no hint
(`test/error_builder_golden_test.exs` "wire output for invalid_union_input_multiple_member_keys is unchanged").
See [errors.md](errors.md).

Union *output* selection (members must be named in `fields`) is in
[field-selection.md](field-selection.md).

## Unconstrained map input

An input whose type is `:map` with no `fields` constraint is passed through
verbatim: the input key itself is mapped like any other (`"data"` → `:data`),
but nothing inside the map is renamed, so snake_case and nested keys survive.
Asserted by `test/unconstrained_map_test.exs`:

- "create round-trips the map verbatim, snake_case and nested keys untouched"
  (`create_post` with the `Post.data` attribute)
- "update replaces the map wholesale, keys untouched" (`update_post`)
- "merges the argument into the existing data" (`merge_post_data`, an update with
  a `:map` argument), "a nil argument leaves the existing data unchanged",
  "merging into nil data sets the argument"
- "returns the payload verbatim without a fields selection" (`echo_map`, a
  generic action with `:map` in and out)

## Runtime name mapping, both directions

All client names are read from decoration on the runtime's lookups; nothing is
introspected live. The fixture overrides are in `test/support/mapping_source.ex`:

| What | Internal | Client | Asserted by |
|---|---|---|---|
| Resource field (`AshRpc.Test.Author`) | `is_active?` | `isActive` | `test/field_formatter_test.exs` "overrides win over the formatter for decorated resources" |
| Action argument (`Post.word_count`) | `text` | `body` | `test/run_action_test.exs` "argument overrides apply to input" |
| Type field (`AshRpc.Test.PostStats`) | `word_count_1` | `wordCount1` | `test/value_formatter_test.exs` "output: mapped NewType fields use decorated overrides" |

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "word_count",
  "input" => %{"body" => "two words"}
})
# => %{"success" => true, "data" => 2}
```

Scope rules (`test/field_name_translation_test.exs`):

- Nested relationship fields use the **related** resource's names ("nested
  relationship fields are translated with the related resource's names").
- A generic action's typed return uses the return type's names, not the
  resource's ("a generic action's typed return is not translated with the
  resource's names").

Lookup calls:

| Direction | Call |
|---|---|
| Internal → client, resource or type field | `AshRpc.FieldFormatter.format_field_for_client(field, resource_or_type, formatter)`: the override wins and is used as-is; `nil` or a module atom falls back to the formatter |
| Internal → client, decorated maps | `AshRpc.Manifest.Custom.field_names/1` (resource), `type_field_names/1` (typed container), `type_member_names/1` (union members), `entrypoint_metadata_field_names/1` (wire entrypoint metadata): forward `%{atom => client}` maps, `%{}` when undecorated (`test/manifest/custom_test.exs`) |
| Client → internal, resource field | `AshRpc.ClientNames.resource_field/3` (exact lookup in `client_field_names`, overrides included) |
| Action argument | `AshRpc.Manifest.Custom.argument_name_override/3` / `original_argument_name/3` |
| Type fields | `AshRpc.Manifest.Custom.type_field_name_overrides_pair/1`, else `AshRpc.Introspection.type_field_name_overrides/2` |
| Client → internal, type field / union member / calc arg / vocabulary | `AshRpc.ClientNames.type_field/3`, `union_member/3`, `calc_arg/4`, `vocabulary/3`: pure map lookups returning `{:ok, atom}` or `:error`; atoms pass through, and no atom is ever created from a client string. `calc_args/4` resolves a whole argument map; action input keys go through `AshRpc.InputFormatter.expected_keys/3` |
| Whether a node is strict on input | `AshRpc.ClientNames.resource_named?/2`, `type_named?/2`: true when the resource or type (or its type lookup entry) carries decorated client names |
| Filter statements and sort strings | `AshRpc.FilterInput.parse/3` and `parse_sort/3`: keep `+`, `++`, `-`, `--` and comma lists; a name that isn't a client name is dropped and reported as `Ash.Error.Query.NoSuchField` / `NoSuchFilterPredicate` with the name as sent |

The readers are asserted in `test/client_names_test.exs` (every formatter,
a custom one included) and `test/filter_input_test.exs`.

Built-in formatters are `:camel_case`, `:pascal_case` and `:snake_case`; a
`{Mod, fun}` or `{Mod, fun, extra_args}` formatter is applied to the field name.
Anything else raises `ArgumentError` in `FieldFormatter.format_field_name/2`.

## `AshRpc.Case`

Internal (`@moduledoc false`) snake/camel/pascal conversions used by the built-in
formatters (`test/field_formatter_test.exs` "Case conversions"). Not public API;
call `AshRpc.FieldFormatter` instead.
