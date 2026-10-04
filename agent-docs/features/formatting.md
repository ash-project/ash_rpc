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
- `runtime` is an `%AshRpc.Runtime{}`. `:input` uses `runtime.input_formatter`,
  `:output` uses `runtime.output_formatter`. Overrides and lookups come from the
  runtime too, never from app config
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
| `{:resource, module}` | Resources, embedded resources, and `:struct`/`:map` types whose effective module is an Ash resource | Input: `AshRpc.Manifest.Custom.original_field_name/2`, else `FieldFormatter.parse_input_field/2`. Output: `FieldFormatter.format_field_for_client/3`. Each value recurses with the manifest field or relationship type |
| `{:union, type}` | `kind: :union` | Member-specific; see [Union input](#union-input) |
| `{:typed_struct, type}` | `:struct`/`:map`/`:tuple`/`:keyword` with type field-name overrides | The type's `custom.ash_rpc` override pair, falling back to `AshRpc.Introspection.type_field_name_overrides/2` (type lookup, then the mapping source's `type_field_names/1`) |
| `{:fields, type}` | `:struct`/`:map`/`:tuple`/`:keyword` without overrides | Formatter only. A type with no `fields` (an unconstrained map) passes through untouched |
| `{:other, type}` | Everything else | Scalars pass through, except `Ash.Type.Vector` (packed binary → list of floats) and non-builtin custom types with `:map` storage (all keys formatted recursively) |

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
  `params["input"]`. The other top-level params (`filter`, `page`, `getBy`, …)
  only get their keys parsed with `FieldFormatter.parse_input_fields/2`; `sort`
  goes through `FieldFormatter.format_sort_string/2`. `input` and `identity` are
  popped before that key parsing.
- **`format_output`** (output): `AshRpc.Pipeline` calls `ValueFormatter.format/5`
  directly (there is no output-formatter module). Non-generic actions are
  formatted against the resource; generic actions use the classification of
  `action.returns`, and an unconstrained-map return is passed through as-is.

See [pipeline.md](pipeline.md) for the stages themselves.

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
- Keys not in the map are passed through unchanged, still as client strings.
- Non-embedded struct inputs whose type is backed by an Ash resource are cast to
  that resource struct after key formatting. Ash casts everything else itself.
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
   the formatted member value. (No fixture covers tagged unions yet.)
2. **Member key.** Otherwise each map key is parsed with the input formatter and
   compared to the member names. Exactly one must match.

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
| Client → internal, resource field | `AshRpc.Manifest.Custom.original_field_name/2` |
| Action argument | `AshRpc.Manifest.Custom.argument_name_override/3` / `original_argument_name/3` |
| Type fields | `AshRpc.Manifest.Custom.type_field_name_overrides_pair/1`, else `AshRpc.Introspection.type_field_name_overrides/2` |
| Client → internal, no override | `AshRpc.FieldFormatter.parse_input_field(name, formatter)`: an existing atom, or the parsed string when no such atom exists (it never creates atoms from client input) |
| Sort strings | `AshRpc.FieldFormatter.format_sort_string(sort, formatter)`: keeps `+`, `++`, `-`, `--` and comma lists, parses each field name |

`format_sort_string/2` and `parse_input_field/2` are asserted in
`test/field_formatter_test.exs` ("format_sort_string/2 keeps every modifier and
parses field names", "parse_input_field/2 returns an existing atom or the parsed
string").

Built-in formatters are `:camel_case`, `:pascal_case` and `:snake_case`; a
`{Mod, fun}` or `{Mod, fun, extra_args}` formatter is applied to the field name.
Anything else raises `ArgumentError` in `FieldFormatter.format_field_name/2`.

## `AshRpc.Case`

Internal (`@moduledoc false`) snake/camel/pascal conversions used by the built-in
formatters (`test/field_formatter_test.exs` "Case conversions"). Not public API;
call `AshRpc.FieldFormatter` instead.
