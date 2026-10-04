<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Manifest Decoration

How an extension turns an `%Ash.Info.Manifest{}` into something the ash_rpc
runtime can serve: the `AshRpc.MappingSource` behaviour, what the decorator
writes under `custom.ash_rpc`, the `%AshRpc.Entrypoint{}` contract, client-name
resolution and formatters.

Key files: `lib/ash_rpc/mapping_source.ex`, `lib/ash_rpc/manifest/decorator.ex`,
`lib/ash_rpc/manifest.ex`, `lib/ash_rpc/manifest/custom.ex`,
`lib/ash_rpc/entrypoint.ex`, `lib/ash_rpc/runtime.ex`.

## What Decoration Is

```elixir
AshRpc.Manifest.Decorator.decorate(manifest, mapping_source, opts \\ [])
```

- **Pure**: manifest in, manifest out. Nothing is stored globally.
- **Idempotent**: decorating an already-decorated manifest gives the same
  result (`test/manifest/decorator_test.exs` "decorate/3 is idempotent").
- **Compile time, extension-owned**: the extension calls it while building its
  manifest. `opts` may override `:input_formatter` / `:output_formatter`;
  everything else comes from the mapping source.
- The runtime never calls the mapping source. The one exception is
  `type_field_names/1`, the fallback for type modules missing from the type
  lookup or carrying no decorated override pair
  (`AshRpc.Introspection.type_field_name_overrides/2`).

## `AshRpc.MappingSource` Callbacks

| Callback | Returns | Used for |
|----------|---------|----------|
| `input_formatter/0` | `formatter()` | Client → internal key parsing at runtime |
| `output_formatter/0` | `formatter()` | Internal → client names, computed at decoration and applied at runtime |
| `exposed_resource?/1` | `boolean()` | Which resources (domain and embedded) get decorated. Everything else stays undecorated (strict exposure) |
| `field_names/1` | `%{atom() => String.t()}` | Client-name **overrides only**; unlisted fields use the output formatter |
| `argument_names/2` | `%{atom() => String.t()}` | Per-action argument overrides `(resource, action)` |
| `type_field_names/1` | map or `nil` | Field overrides for a type module; `nil` = none |
| `entrypoint/1` | `%AshRpc.Entrypoint{}` or `nil` | Turns an `%Ash.Info.Manifest.Entrypoint{}` into a wire action; `nil` keeps it off the wire |

`formatter()` is `:camel_case | :snake_case | :pascal_case | {module, fun} |
{module, fun, extra_args}` (`@type formatter` in `mapping_source.ex`). A custom
`{Mod, fun}` formatter is supported end to end (`test/manifest/decorator_test.exs`
"custom {Mod, fun} output formatter").

The test fixture `test/support/mapping_source.ex` is a complete example. Its
field and argument override clauses (it also maps `AshRpc.Test.PostStats` in
`type_field_names/1`):

```elixir
@impl true
def field_names(AshRpc.Test.Author), do: %{is_active?: "isActive", is_prolific?: "isProlific"}
def field_names(_resource), do: %{}

@impl true
def argument_names(AshRpc.Test.Post, :word_count), do: %{text: "body"}
def argument_names(_resource, _action), do: %{}
```

## What Lands Under `custom.ash_rpc`

### Manifest level

Read with `AshRpc.Manifest`:

| Key | Reader |
|-----|--------|
| `mapping_source` | `mapping_source/1` |
| `input_formatter`, `output_formatter` | `input_formatter/1`, `output_formatter/1` |
| `entrypoints` (`%{wire_name => %AshRpc.Entrypoint{}}`) | `entrypoint_lookup/1` |
| `lookups.resource` (includes embedded resources), `lookups.type`, `lookups.action` | `resource_lookup/1`, `type_lookup/1`, `action_lookup/1` |

`AshRpc.Manifest.put_lookups/1` rebuilds `lookups` from the manifest as it is
now; the decorator calls it last. An extension that runs its own decorators
afterwards must call it again after the last one that touches resources, types
or actions. `ash_rpc!/1` raises `ArgumentError` on an undecorated manifest.

Asserted by `test/manifest/decorator_test.exs` "manifest-level custom.ash_rpc"
and "lookups are embedded and merge embedded resources".

### Element level

Read with `AshRpc.Manifest.Custom` (every accessor returns `nil` or an empty
default for undecorated structs):

| Element | Data | Accessors |
|---------|------|-----------|
| Exposed resource (domain or embedded) | Full client `field_names` (fields and relationships), the overrides and their reverse, per-action argument overrides and their reverse, `authorize_bulk_strategy` | `exposed?/1`, `field_names/1`, `field_name_override/2`, `original_field_name/2`, `argument_name_override/3`, `original_argument_name/3`, `authorize_bulk_strategy/1` |
| Many-cardinality relationship to an exposed destination | `pagination` (`:offset`, `:keyset`, `:mixed`, `:none`) and `read_action` (the relationship's, else the destination's primary read) | `relationship_pagination/1`, `relationship_read_action/1` |
| Type with `type_field_names/1` overrides | Overrides and their reverse | `type_field_name_overrides/1`, `type_field_name_overrides_pair/1` |
| Every entrypoint action | `expected_input_keys` (client key → input name), `input_field_types`, `return_classification` | `action_expected_input_keys/1`, `action_input_field_types/1`, `action_return_classification/1` |

Tests in `test/manifest/decorator_test.exs`: "exposed resources carry
precomputed names; overrides win", "argument overrides are scoped per action",
"unexposed resources are left undecorated (strict exposure)", "embedded
resources are decorated and in the resource lookup", "mapped types carry
overrides", "entrypoint actions carry expected input keys, field types and
return classification".

An unexposed resource (the fixture `AshRpc.Test.Secret`) carries no
`custom.ash_rpc`, so `Custom.exposed?/1` is false and selecting it through a
relationship is `unknown_field` (see [field selection](field-selection.md)).

## `AshRpc.Entrypoint` Fields

The per-action contract returned by `entrypoint/1`. Defaults are from
`defstruct` in `lib/ash_rpc/entrypoint.ex` (`test/entrypoint_test.exs`
"defaults match the spec contract").

| Field | Default | Runtime effect |
|-------|---------|----------------|
| `name` | — | Wire action name; key in `custom.ash_rpc.entrypoints`, matched against `params["action"]`. Duplicate names raise `ArgumentError` at decoration |
| `domain` | `nil` | Passed as `domain:` to bulk update/destroy, and in the error scope, where it selects the profile's `error_handler/1` and `show_raised_errors?/1` ([errors](errors.md)) |
| `resource` | — | Resource the action runs on |
| `action` | — | Action name, resolved through `AshRpc.Introspection.get_action!/3` on the runtime's action lookup |
| `read_action` | `nil` | Read action used to load the update/destroy target (also in `validate_action`); `nil` = the resource's primary read ([pipeline](pipeline.md)) |
| `get?` | `false` | Read returns a single record, not a list; top-level filter/sort/page become unsupported ([pipeline](pipeline.md)) |
| `get_by` | `[]` | Fields read from the `getBy` param; non-empty also implies a single-record read ([pipeline](pipeline.md)) |
| `identities` | `[:_primary_key]` | Identities accepted in the `identity` param for update/destroy. `[]` = no identity; the target comes from `read_action` (actor-scoped actions) ([pipeline](pipeline.md)) |
| `not_found_error?` | `true` | A get that finds nothing is an error; `false` returns `data: nil` |
| `enable_filter?` | `true` | `false` makes top-level and nested `filter` a `filter_not_supported` with reason `disabled` |
| `enable_sort?` | `true` | Same for `sort` / `sort_not_supported` |
| `load_restrictions` | `:none` | `{:allow, tree}` or `{:deny, tree}`; normalized in `parse_request`, enforced in the field selector ([field selection](field-selection.md)) |
| `exposed_metadata_fields` | `[]` | Action metadata the client may request ([action metadata](action-metadata.md)) |
| `metadata_field_names` | `%{}` | Internal → client names for metadata fields ([action metadata](action-metadata.md)) |
| `preset_fields` | `nil` | Not read by the pipeline. Carried for entrypoints an extension resolves outside the wire and passes with the `entrypoint:` option |

An entrypoint passed with `entrypoint:` to `AshRpc.run_action/4` bypasses the
`params["action"]` lookup entirely (`discover_entrypoint/3` in `pipeline.ex`).

## Example `entrypoint/1`

```elixir
defmodule MyExt.MappingSource do
  @behaviour AshRpc.MappingSource
  # ...other callbacks...

  @impl true
  def entrypoint(%Ash.Info.Manifest.Entrypoint{resource: AshRpc.Test.Post, action: %{name: :read}}) do
    %AshRpc.Entrypoint{
      name: "list_posts_allow_author",
      domain: AshRpc.Test.Domain,
      resource: AshRpc.Test.Post,
      action: :read,
      load_restrictions: {:allow, [:author]}
    }
  end

  def entrypoint(_), do: nil
end
```

This matches every `Post` `:read` entrypoint, so it only works when there is
one; with several, match on `config` the way the fixture does, or decoration
hits the duplicate-name `ArgumentError`.

The test fixture builds the same struct generically: each row of
`@entrypoints` in `test/support/manifest_builder.ex` carries its name and opts
in the entrypoint `config`, and `AshRpc.Test.MappingSource.entrypoint/1`
applies the opts with `struct!/2`. A typo in a row opt raises `KeyError`, so the
manifest build fails (`test/fixtures_test.exs` "an unknown entrypoint opt fails
the manifest build"). The `list_posts_allow_author` row is
`{"list_posts_allow_author", AshRpc.Test.Post, :read, load_restrictions: {:allow, [:author]}}`.

## Client Name Resolution

- For each exposed resource, every field and relationship gets a client name:
  the `field_names/1` override if present, otherwise the output formatter's
  result. At runtime `AshRpc.FieldFormatter.format_field_for_client/3` applies
  the same rule, and an override wins whatever formatter is passed
  (`test/field_formatter_test.exs` "overrides win over the formatter for
  decorated resources").
- Expected input keys per entrypoint action: accepted attributes use the
  resource's `field_names/1` override, arguments the `argument_names/2`
  override; otherwise the output formatter (`test/manifest/redecorate_test.exs` "expected input keys
  follow the new output formatter").
- Two fields or two action inputs mapping to the same client name raise
  `AshRpc.Manifest.NameCollisionError` at decoration
  (`test/manifest/decorator_test.exs` "two fields formatting to the same client
  name raise").
- A formatter that returns a non-string, or raises, makes decoration raise
  `ArgumentError` naming the formatter and field
  (`test/manifest/decorator_test.exs` "a formatter returning a non-string raises
  naming formatter and field").

## Formatters Are Fixed at Decoration

`AshRpc.Runtime.new/2` reads the formatters from `custom.ash_rpc`; nothing reads
them from application config at request time. To vary them in a test:

`AshRpc.Manifest.redecorate/2` re-runs the decorator with the stored mapping
source; if that mapping source isn't loaded it raises `ArgumentError`
(`test/manifest/redecorate_test.exs`). See [testing](../testing.md) for the
recipe (`redecorate/2` or `ManifestBuilder.build/1` plus the `manifest:`
option), and [pipeline](pipeline.md) for how the runtime threads the result through a
request.
