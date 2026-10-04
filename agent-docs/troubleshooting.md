<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Troubleshooting

Symptom → cause → fix for the runtime. For one-line error lookups, check the
**Common Errors** table in [`AGENTS.md`](../AGENTS.md#common-errors) first. This
file covers the cases that need more context, and how to reproduce any problem
in a test.

## Reproduce It in a Test

Debug with a test, never in a shell (`AGENTS.md` Rule 4). The fixtures
(`AshRpc.Test.*`) only compile in `:test`. Write a module under `test/`, run it
with `mix test test/<file>.exs`, and use `dbg/1` to inspect values. When you
are done, delete it or keep it as a regression test with the `dbg/1` calls
removed (credo flags them).

```elixir
defmodule AshRpc.ReproTest do
  use ExUnit.Case, async: true

  alias AshRpc.RequestedFieldsProcessor

  @profile AshRpc.Test.Profile

  test "wire view: what the client gets back" do
    params = %{"action" => "list_posts", "fields" => ["id", %{"author" => ["name"]}]}

    assert %{"success" => true, "data" => _} =
             AshRpc.run_action(@profile, %AshRpc.Context{}, params) |> dbg()
  end

  test "field-selection view: select, load and extraction template" do
    runtime = AshRpc.Runtime.new(@profile)

    assert {:ok, {[:id], [author: [:name]], [:id, {:author, [:name]}]}} =
             RequestedFieldsProcessor.process(runtime, AshRpc.Test.Post, :read, [
               :id,
               %{author: [:name]}
             ])
  end
end
```

- **Wire view.** `AshRpc.run_action/4` runs all four stages and returns the
  client-formatted map, errors included. Start here: it shows exactly what a
  client sees.
- **Field-selection view.**
  `AshRpc.RequestedFieldsProcessor.process(runtime, resource, action, fields, opts \\ [])`
  returns `{:ok, {select, load, extraction_template}}` or `{:error, reason}`,
  where `reason` is the raw pipeline tuple (e.g.
  `{:unknown_field, :secret, AshRpc.Test.Post, path}`) before `ErrorBuilder`
  turns it into a wire error. It accepts atom or client-string field names.
  To apply the resource's field-name overrides first, call
  `RequestedFieldsProcessor.atomize_requested_fields(fields, resource, runtime)`,
  as `test/field_selector_test.exs` does.
- **Stage view.** To stop after a given stage, call the `AshRpc.Pipeline`
  functions directly. See [pipeline](features/pipeline.md).
- **A variant manifest.** Build one with
  `AshRpc.Test.ManifestBuilder.build/1` or `AshRpc.Manifest.redecorate/2` and
  pass `manifest:`. See [testing](testing.md).

## Field Selection

See [field selection](features/field-selection.md) for the full rules.

### `unknown_field` for a relationship that exists

**Cause:** strict exposure. The relationship's destination is not exposed by
the mapping source (`exposed_resource?/1` returns false), so the decorator
leaves it undecorated and the field selector refuses to walk into it. The
resource is still in the resource lookup, so a lookup alone won't tell you;
check `AshRpc.Manifest.Custom.exposed?/1` on it. In the fixtures, `Post.secret`
→ `AshRpc.Test.Secret` is unexposed on purpose
(`test/field_selector_test.exs` "a relationship to an unexposed resource is
unknown_field").

**Fix:** expose the destination in the mapping source. In the test suite, add
it to `@exposed` in `test/support/mapping_source.ex` (never `Secret`).

### `requires_field_selection`

**Cause:** the field returns something with its own fields (an embedded
resource, a typed map or struct, a union, or a resource-returning calculation)
and was requested by bare name. `vars.fieldType` names the kind.

**Fix:** pass a nested selection: `%{"selfPost" => ["id"]}`, or for a
calculation with arguments `%{"scoredStats" => %{"args" => …, "fields" => […]}}`.
An empty `fields` list counts as missing. Unions select members by name
(`%{"count" => ["number", "label"]}`). Tests: `test/calculations_test.exs`
"requires_field_selection" describe, `test/typed_field_selection_test.exs`
"requires_field_selection on typed values", `test/union_input_test.exs`
"output selection must name members".

### Calculation argument errors

| Wire `type` | Cause | Test (`test/calculations_test.exs`) |
|---|---|---|
| `invalid_field_format` | A calculation that takes arguments requested as a bare name (`"excerpt"`). Internally `{:calculation_requires_args, …}` | "calculation_requires_args: a calculation with arguments requested as a bare name" |
| `invalid_calculation_args` | `args` on a calculation that takes none, or `fields` without `args` on one that does | "invalid_calculation_args" describe |
| `invalid_field_selection` | A `fields` key on a scalar calculation | "invalid_field_selection: a fields key on a scalar calculation" |
| `field_does_not_support_nesting` | A nested list on a scalar calculation (`%{"titleLength" => ["x"]}`) | "field_does_not_support_nesting: nested fields on a scalar calculation" |
| `duplicate_field` | The same calculation requested twice with different args | "duplicate_field: the same calculation requested twice with different args" |

The `args` map is not checked against the calculation's argument names by the
field selector. An argument name the calculation doesn't define is rejected
later by Ash when the load runs, with `path: ["load"]`. Arg keys reach Ash as
strings, so the wire type depends on the atom table. A key that names an
existing atom gives `Ash.Error.Invalid.NoSuchInput`, which has no
`AshRpc.Error` impl: the client gets `internal_error` with an `errorId`, and a
warning is logged. A key that names no existing atom fails atom conversion and
becomes `unknown_error` (`test/calculations_test.exs` "an args key the calculation doesn't define
fails when Ash builds the load").

### Embedded resource fields missing or erroring

**Cause:** the embedded field was requested by bare name, or a calculation
inside it is load-restricted. An embedded resource is selected like a
relationship, with a nested field list
(`%{"settings" => ["themeName", "themeLabel"]}`). A bare `"settings"` is `requires_field_selection` with `fieldType`
`Embedded_resource` (`test/typed_field_selection_test.exs` "a bare embedded
field is requires_field_selection"). A calculation on the embedded resource (`themeLabel`) is a
load, so the entrypoint's load restrictions apply to it
(`test/load_restrictions_test.exs` "an embedded resource calculation is a
load").

**Fix:** select the embedded fields explicitly. If a calculation inside it is
rejected with `load_not_allowed`, adjust the entrypoint's `load_restrictions`.

## Union Input

Union input must be wrapped: a map with exactly one key naming the member,
`%{"count" => %{"number" => 3}}`. All three wrong shapes return
`invalid_union_input`; the `message` tells them apart. Asserted end to end in
`test/union_input_test.exs`, using `AshRpc.Test.Ledger.count`
(`number: :integer`, `label: :string`) through `create_ledger`.

| Sent `"count" =>` | `message` | Fix |
|---|---|---|
| `3` | "Union input must be a map with exactly one member key" (`details.suggestion` shows the format) | Wrap it: `%{"number" => 3}` |
| `%{"other" => 1}` | "Union input map does not contain any valid member key" (`vars.expectedMembers` = `"number, label"`) | Use a member name from `vars.expectedMembers` |
| `%{"number" => 1, "label" => "x"}` | "Union input map contains multiple member keys: %{foundKeys}" | Send exactly one member key |

See [formatting](features/formatting.md) for how members, including tagged
ones, are matched.

## Name Mapping

See [formatting](features/formatting.md) and
[decoration](features/decoration.md).

### A client name isn't translated (input ignored, output in the wrong case)

**Causes, in order of likelihood:**

1. **The override is missing from the decoration.** The runtime reads names
   only from `custom.ash_rpc` in the manifest, never from the resource (the one
exception is the mapping source's `type_field_names/1` fallback for types). Inspect
   what the decorator stored:

   ```elixir
   manifest = AshRpc.Test.ManifestBuilder.manifest()
   resource = AshRpc.Manifest.resource_lookup(manifest)[AshRpc.Test.Author]

   AshRpc.Manifest.Custom.field_names(resource)
   # => %{id: "id", name: "name", is_active?: "isActive", is_prolific?: "isProlific", ...}

   AshRpc.Manifest.Custom.field_name_overrides(resource)
   # => %{is_active?: "isActive", is_prolific?: "isProlific"}
   ```

   Arguments live per action (`AshRpc.Manifest.Custom.argument_name_overrides/2`);
   typed-map and struct fields live on the type
   (`AshRpc.Manifest.Custom.type_field_name_overrides/1` on an entry of the
   type lookup, `AshRpc.Manifest.type_lookup/1`). If the name isn't there, the
   mapping source didn't return it.
2. **The formatter was changed after decoration.** Formatters are fixed when
   the manifest is decorated; changing app config at runtime does nothing. Use
   `AshRpc.Manifest.redecorate(manifest, output_formatter: …)` and pass
   `manifest:` (`test/run_action_test.exs` "manifest: option changes output
   casing").
3. **The manifest wasn't rebuilt.** An extension that decorates at compile time
   serves the old names until its manifest module recompiles. In this suite,
   `ManifestBuilder.manifest/0` is cached in `:persistent_term`; use
   `build/1` for a variant.
4. **The resource isn't exposed.** Unexposed resources carry no names and
   aren't reachable at all (see `unknown_field` above).

Nested relationships use the related resource's names
(`test/field_name_translation_test.exs`).

## Action Metadata Not in the Response

See [action metadata](features/action-metadata.md).

1. **Not exposed.** Only fields in the entrypoint's `exposed_metadata_fields`
   are returned; anything else requested is silently dropped
   (`test/action_metadata_test.exs` "requested fields that are not exposed are
   silently dropped", "an entrypoint exposing no metadata drops every requested
   field").
2. **Not requested on a read.** Read actions merge metadata into each record
   only for fields named in `metadataFields`; with no param, none is merged
   ("no metadataFields param merges no metadata").
3. **Looking in the wrong place.** Create, update and destroy return every
   exposed field under a top-level `metadata` key, not inside the record
   ("create returns every exposed field under a top-level metadata key").
4. **Mapped name.** Output uses `metadata_field_names` (`meta_1` → `meta1`),
   even when the request used the original name ("original names are accepted
   in requests but output stays mapped").
5. **The action never sets it.** The value comes from the Ash action itself
   (see `test/support/changes.ex`).

## Runtime Processing

| Symptom | Cause | Fix |
|---|---|---|
| `ArgumentError` "the manifest used by … has no custom.ash_rpc decoration" | A raw `Ash.Info.Manifest` reached `AshRpc.Runtime.new/2` (e.g. `ManifestBuilder.generate!/1` output passed as `manifest:`) | Decorate it with `AshRpc.Manifest.Decorator.decorate/3` (`test/runtime_test.exs` "an undecorated profile manifest raises ArgumentError naming the profile") |
| `action_not_found` (`vars.actionName`) | The wire name isn't in the manifest's entrypoints: missing from `@entrypoints` in `test/support/manifest_builder.ex`, or the mapping source's `entrypoint/1` returned `nil` | Add the row (`test/run_action_test.exs` "unknown action and missing action") |
| `missing_required_parameter` | No `action` param and no `entrypoint:` option | Send `action`, or pass `entrypoint:` |
| A test sees stale or unexpected config | It mutated, or expected a change in, the cached `ManifestBuilder.manifest/0` | Build a fresh one with `build/1` |
| `internal_error` or `unknown_error` with `path: ["load"]` | Ash rejected the load built from the selection (e.g. an `args` key the calculation doesn't define; `test/calculations_test.exs` "an args key the calculation doesn't define fails when Ash builds the load") | Reproduce with the field-selection view above and check the calculation's arguments |
| Any other wire error | Look up the `type` in [`AGENTS.md`](../AGENTS.md#common-errors) Common Errors, then the `type`'s `build/2` clause in `lib/ash_rpc/error_builder.ex` | See [errors](features/errors.md) |
