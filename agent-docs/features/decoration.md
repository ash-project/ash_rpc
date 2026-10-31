<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Manifest Decoration

How an extension turns an `%Ash.Info.Manifest{}` into something the ash_rpc
runtime can serve: the `AshRpc.MappingSource` behaviour, what the decorator
writes under `custom.ash_rpc`, the `%AshRpc.Entrypoint{}` contract, client-name
resolution and the output formatter.

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
  manifest. `opts` may override `:output_formatter`; everything else comes
  from the mapping source.
- The runtime never calls the mapping source. The one exception is
  `type_field_names/1`, the fallback for type modules missing from the type
  lookup or carrying no decorated override pair
  (`AshRpc.Introspection.type_field_name_overrides/2`).

## `AshRpc.MappingSource` Callbacks

| Callback | Returns | Used for |
|----------|---------|----------|
| `output_formatter/0` | `formatter()` | Internal → client names, computed at decoration (forward and reverse maps) and applied to output at runtime. The only formatter: client input is matched against its names exactly |
| `exposed_resource?/1` | `boolean()` | Which resources (domain and embedded) get the source's overrides and count as exposed. An unexposed embedded resource is still decorated with formatter-only names, and so is an unexposed domain resource an entrypoint takes as a struct input; any other unexposed domain resource stays undecorated (strict exposure) |
| `field_names/1` | `%{atom() => String.t()}` | Client-name **overrides only**; unlisted fields use the output formatter |
| `argument_names/2` | `%{atom() => String.t()}` | Per-action argument overrides `(resource, action)` |
| `type_field_names/1` | map or `nil` | Field overrides for a type module; `nil` = none |
| `entrypoint/1` | `%AshRpc.Entrypoint{}` or `nil` | Turns an `%Ash.Info.Manifest.Entrypoint{}` into a wire action; `nil` keeps it off the wire |
| `custom_type_fields/1` (optional) | `[field_spec()]` or `nil` | Fields for a custom `use Ash.Type` module (a `kind: :unknown` node); see [Declared Custom Types](#declared-custom-types) |
| `custom_type_fields_hint/1` (optional) | `String.t()` or `nil` | Extra text for the error about a map-like custom type without fields, appended after a blank line |

A `field_spec()` is `{name, opts}` in the format of a typed map's `fields`
constraint: `type:` (required), `constraints:`, `allow_nil?:` (default
`true`), `description:`, plus `client_name:`, the field's client name. A
declared type is named by its specs alone: a field without `client_name:` gets
the formatter's name, and `type_field_names/1` isn't read for the type, at
decoration or at runtime. `decorate/3`'s
`custom_type_fields:` option (a function of the module) replaces the callback,
for an extension whose declarations need state the bare mapping source can't
reach; its `custom_type_fields_hint:` option (a string, or a function of the
module returning a string or `nil`) replaces `custom_type_fields_hint/1` the
same way. Without either, nothing is declared, and a wire use of a map-like
custom type fails decoration ([Untyped Structs Are Rejected](#untyped-structs-are-rejected)).

`formatter()` is `:camel_case | :snake_case | :pascal_case | {module, fun} |
{module, fun, extra_args}` (`@type formatter` in `mapping_source.ex`). A custom
`{Mod, fun}` formatter is supported end to end and needs no inverse
(`test/manifest/decorator_test.exs` "custom {Mod, fun} output formatter";
`test/field_name_translation_test.exs` "wire round trip" with
`AshRpc.Test.Formatters.upcase/1`).

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
| `output_formatter` | `output_formatter/1` |
| `vocabulary` (`%{scope => %{client_name => atom}}`) | `vocabulary/1`; on the runtime as `runtime.vocabulary` |
| `entrypoints` (`%{wire_name => %AshRpc.Entrypoint{}}`) | `entrypoint_lookup/1` |
| `lookups.resource` (includes embedded resources), `lookups.type`, `lookups.action` | `resource_lookup/1`, `type_lookup/1`, `action_lookup/1` |

`AshRpc.Manifest.put_lookups/1` rebuilds `lookups` from the manifest as it is
now; the decorator calls it last. An extension that runs its own decorators
afterwards must call it again after the last one that touches resources, types
or actions. `ash_rpc!/1` raises `ArgumentError` on an undecorated manifest.

Asserted by `test/manifest/decorator_test.exs` "manifest-level custom.ash_rpc"
and "lookups are embedded and merge embedded resources".

`vocabulary` holds the fixed request names, formatted with the output
formatter, in four scopes (`test/manifest/decorator_test.exs` "vocabulary"):

| Scope | Internal names |
|-------|----------------|
| `:params` | `action`, `input`, `identity`, `fields`, `get_by`, `filter`, `sort`, `page`, `tenant`, `metadata_fields` |
| `:page` | `limit`, `offset`, `count`, `after`, `before` |
| `:query_opts` | nested envelope keys: `page`, `filter`, `sort`, `limit`, `offset`, `args`, `fields` |
| `:filter_ops` | `and`, `or`, `not`, `input`, every `Ash.Filter` built-in operator name, the aliases `equals`/`not_equals`/`gt`/`lt`/`gte`/`lte`, and every built-in function name |

### Element level

Read with `AshRpc.Manifest.Custom` (every accessor returns `nil` or an empty
default for undecorated structs):

| Element | Data | Accessors |
|---------|------|-----------|
| Exposed resource (domain or embedded) | Full client `field_names` (fields and relationships) and their reverse `client_field_names`, `calculation_argument_names` (`%{calc => %{client => arg}}`), the overrides and their reverse, per-action argument overrides and their reverse, `authorize_bulk_strategy` | `exposed?/1`, `field_names/1`, `client_field_names/1`, `calculation_argument_names/2`, `field_name_override/2`, `original_field_name/2`, `argument_name_override/3`, `original_argument_name/3`, `authorize_bulk_strategy/1` |
| Embedded resource the source doesn't expose | The same names, from the output formatter alone: empty overrides, no argument overrides, and `exposed: false`. `field_names/1` and `argument_names/2` are never called for it | `client_field_names/1`, `field_names/1`, `original_field_name/2`; `exposed?/1` is false |
| Unexposed domain resource taken as a struct input (an entrypoint action input of `kind: :resource`, directly, in an array, or nested in a typed container, union or named type) | The same formatter-only names and `exposed: false` as an unexposed embedded resource | As above |
| Many-cardinality relationship to an exposed destination | `pagination` (`:offset`, `:keyset`, `:mixed`, `:none`) and `read_action` (the relationship's, else the destination's primary read) | `relationship_pagination/1`, `relationship_read_action/1` |
| Type with named fields (typed map, keyword, tuple, TypedStruct), in `manifest.types` or inline on a field, argument, input, return or metadata | `field_names` and their reverse `client_field_names`; plus the overrides and their reverse when `type_field_names/1` maps the module | `type_field_names/1`, `type_client_field_names/1`, `type_field_name_overrides/1`, `type_field_name_overrides_pair/1` |
| Declared custom type's definition in `manifest.types` (see [Declared Custom Types](#declared-custom-types)) | The typed-map names above, plus `custom_type: true`; `client_name:` values from the field specs are its `field_name_overrides` | `custom_type?/1`, plus the type accessors above |
| Union type | `client_member_names` (`%{client => member}`) | `type_client_member_names/1`; `type_member_names/1` is the forward map (`%{member => client}`) |
| Every entrypoint action | `expected_input_keys` (client key → input name), `input_field_types`, `return_classification` | `action_expected_input_keys/1`, `action_input_field_types/1`, `action_return_classification/1` |
| Wire entrypoint (`%AshRpc.Entrypoint{}`) | `client_metadata_field_names` (`%{client => field}`) | `entrypoint_metadata_field_names/1` (the forward map, `%{field => client}`) |

`type_field_names/1`, `type_member_names/1` and
`entrypoint_metadata_field_names/1` return `%{}` for an undecorated node. The
forward maps are safe inversions of the stored reverse maps, because decoration
raises `NameCollisionError` on duplicate client names
(`test/manifest/custom_test.exs`).

Tests in `test/manifest/decorator_test.exs`: "exposed resources carry
precomputed names; overrides win", "argument overrides are scoped per action",
"unexposed resources are left undecorated (strict exposure)", "embedded
resources are decorated and in the resource lookup", "mapped types carry
overrides", "entrypoint actions carry expected input keys, field types and
return classification", "unexposed domain resources used as struct inputs get
formatter names".

An unexposed domain resource (the fixture `AshRpc.Test.Secret`) carries no
`custom.ash_rpc`, so `Custom.exposed?/1` is false and selecting it through a
relationship is `unknown_field` (see [field selection](field-selection.md)).

An unexposed domain resource that an entrypoint takes as a struct input (the
fixture `AshRpc.Test.Voucher`, the `voucher` argument of
`Catalog.redeem_voucher`) is decorated with formatter-only names and
`exposed: false`, so its input keys resolve (and are strict) like an
unexposed embedded resource's. Relationship gating stays strict: selecting
`Post.vouchers` is still `unknown_field`. Tests: "a struct input on an
unexposed domain resource takes formatter names" and "... has strict keys"
(`test/complex_input_test.exs`), "a relationship to an unexposed resource
decorated as a struct input stays unknown_field"
(`test/unexposed_embedded_test.exs`).

An unexposed embedded resource (the fixture `AshRpc.Test.QuoteBlock`, reached
through `Widget.caption` and the `Widget.aside` union) is decorated so its
fields can be selected and its input keys resolved, under output-formatter
names. Its payload carries `exposed: false`, so `Custom.exposed?/1` stays
false. That flag only gates relationship destinations, which an embedded
resource never is, so no exposure gate opens. Its nested input keys are strict
like any decorated resource's (`test/unexposed_embedded_test.exs`).

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
| `client_metadata_field_names` | `%{}` | Written by the decorator on wire entrypoints: client → internal names for every exposed metadata field. Mapping sources leave it unset |
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
  result. An unexposed embedded resource gets the output formatter's result
  for every field. At runtime `AshRpc.FieldFormatter.format_field_for_client/3` applies
  the same rule, and an override wins whatever formatter is passed
  (`test/field_formatter_test.exs` "overrides win over the formatter for
  decorated resources").
- Expected input keys per entrypoint action: accepted attributes use the
  resource's `field_names/1` override, arguments the `argument_names/2`
  override; otherwise the output formatter (`test/manifest/redecorate_test.exs` "expected input keys
  follow the new output formatter").
- Every type tree is walked bottom-up (`Decorator.decorate_type/4`, public):
  `manifest.types`, exposed resource fields and calculation arguments, and
  each entrypoint action's inputs, returns and metadata. Resource and
  named-reference nodes are skipped; their names live on the resource or the
  named type. Extensions call `decorate_type/4` (with the same
  `custom_type_fields:` option they pass `decorate/3`) for types that never
  enter the manifest; an undecorated type resolves no names, and its input keys
  pass as sent instead of being checked (`test/manifest/decorator_test.exs`
  "type names").
- At runtime client names are resolved by exact lookup in these reverse maps
  (`AshRpc.ClientNames`); no formatter is applied to a client string and no
  atom is created from one (`test/client_names_test.exs`).
- Two fields or two action inputs mapping to the same client name raise
  `AshRpc.Manifest.NameCollisionError` at decoration
  (`test/manifest/decorator_test.exs` "two fields formatting to the same client
  name raise").
- A formatter that returns a non-string, or raises, makes decoration raise
  `ArgumentError` naming the formatter and field
  (`test/manifest/decorator_test.exs` "a formatter returning a non-string raises
  naming formatter and field").

## Declared Custom Types

A custom `use Ash.Type` module is a `kind: :unknown` node in the manifest, with
no fields. When the mapping source's `custom_type_fields/1` (or `decorate/3`'s
`custom_type_fields:` option) returns field specs for it, decoration
(`AshRpc.Manifest.CustomTypes`, called from `decorate/3`) makes it a typed
map:

- **One definition per module.** `manifest.types` gets a named
  `%Ash.Info.Manifest.Type{kind: :map, name: <last module segment>, module: Mod,
  instance_of: nil, constraints: <Ash.Type.init(Mod, []) or []>, fields: [...]}`,
  marked `custom.ash_rpc.custom_type: true` (`AshRpc.Manifest.Custom.custom_type?/1`).
  Each spec resolves as Ash resolves a typed map's `fields`. It is decorated
  like any named type, so it gets `field_names` and `client_field_names`.
- **Uses become `:type_ref`s** to it, keeping the use's constraints and
  `allow_nil?`. Everything downstream (field selection, input keys,
  extraction, return classification) is typed-map machinery: a bare selection
  is `requires_field_selection`, and an undeclared input key is
  `unknown_input`.
- **Fields are per module.** A use-site constraint never changes the
  definition. An extension that derives fields from `composite_types/1` calls
  it with the default constraints (the test mapping source does).
- **A NewType over a custom type** already has a `manifest.types` entry
  `kind: :unknown` (its uses are already `:type_ref`s). Decoration asks about
  the NewType module and, when it declares fields, replaces that entry in
  place. Any other existing entry for a declared module raises
  `ArgumentError` ("already has a manifest.types entry").
- **Inside declared fields**, custom types are asked about in turn (a type
  that nests itself is one recursive named type), named types the manifest
  lacks are resolved and added (`AshRpc.Test.AmountBreakdown` is reached only
  through `Amount`), and resources must already be in the manifest
  (`ArgumentError` naming the custom type, the field and the resource).
- **`:extra_types`** (a list of `%Ash.Info.Manifest.Type{}`) declares custom
  types used only outside the manifest, so their definitions land in
  `manifest.types`. `decorate_type/4` rewrites a declared use with the same
  `custom_type_fields:` option or callback; its caller puts the definition in
  the manifest through `:extra_types`.
- **Re-decorating** (`AshRpc.Manifest.redecorate/2`, or `decorate/3` on a
  decorated manifest) keeps the definitions, the marker and the spec client
  names: uses are already `:type_ref`s, so nothing is asked again, and an
  existing definition stays as it is even when an unexposed resource's
  `:unknown` use makes the module be asked about again.
- An empty or malformed spec list, a field name declared twice, or a
  `client_name:` collision, raises (`ArgumentError` naming the module,
  `NameCollisionError`).
- **Undeclared map-like types** (`storage_type :map` or composite where
  used) that a wire entrypoint reaches fail decoration with
  `UntypedStructError`; see [Untyped Structs Are Rejected](#untyped-structs-are-rejected).
  Scalar custom types need no declaration.

Tests: `test/manifest/custom_types_test.exs` (decoration),
`test/custom_type_fields_test.exs` (the wire), and the custom-type tests in
`test/typed_field_selection_test.exs`.

## Untyped Structs Are Rejected

A struct type the manifest has no field types for can't be selected, named or
filtered, and every field would reach the client. `decorate/3` raises
`AshRpc.Manifest.UntypedStructError` when a wire entrypoint can reach one, or
an undeclared map-like custom type (below).
`AshRpc.Introspection.untyped_struct?/1` is the definition: `kind: :struct`,
`fields: nil`, and an `instance_of` that is nil or not an Ash resource; or
`fields: []` with no `instance_of` or `instance_of` a plain module (not an Ash
type or resource): a struct the action returns would reach the client with all
its own fields. An empty field list is typed only with `instance_of` an Ash
type (an empty TypedStruct). In the manifest that is:

- `:struct` with no constraints, or with `fields: []` and no `instance_of`
  (`test/untyped_struct_test.exs` "a :struct with an empty field list and no
  instance_of")
- `:struct` with `instance_of` a plain `defstruct` module and no `fields`, or
  `fields: []` (`test/untyped_struct_test.exs` "a plain struct instance_of
  with an empty field list")
- `:struct` with `instance_of` an Ash type (a TypedStruct or NewType):
  `:struct` doesn't take fields from it, so the manifest has none
- a NewType over any of these
- any of these inside a declared custom type's fields, at any depth (the path
  names the field: `returns → point`)

`:struct` with `instance_of` a resource is a `:resource` node, and `:struct`
with non-empty `fields` (with or without `instance_of`) is a typed container;
both pass.

**Undeclared map-like custom types.** A custom `use Ash.Type` node that is
still `kind: :unknown` after decoration (no declared fields) is rejected when
its module is map-like at that use:
`AshRpc.Introspection.map_like_custom_type?(module, constraints)` (`@doc
false`) is true for a loadable Ash type whose
`Ash.Type.storage_type(module, constraints)` is `:map`, or whose
`composite?(constraints)` is true. Storage is checked first, and neither
callback is rescued. The constraints are the node's, the ones given where it
is used, so a type whose storage depends on a constraint
(`AshRpc.Test.StorageSwitch`) is rejected only where it is map-like. Other
custom types (scalar storage, not composite, or not loadable Ash types) are
opaque, like `:term`. `composite_types/1` is never walked: a composite type
is either declared (and then a `:type_ref`, walked through its definition) or
rejected. A type that describes its fields only through a non-Ash function
(`typed_struct_fields/0`) or lists entries with `composite?/1` false is
undeclared, and rejected when its storage is `:map`.

`AshRpc.Introspection.find_untyped_struct(type, lookups)` returns
`{path, node}` for the first hit or `nil`. It follows array items (segment
`[]`), the `fields` of maps, structs and keywords, tuple `element_types`,
union members, `:type_ref` named types, and resource and embedded-resource
nodes: their fields (attributes, calculations, aggregates, then each
calculation's arguments) in name order, then their relationships in name
order. A relationship is followed only to an exposed destination, since one
to an unexposed resource is `unknown_field`; resource nodes reached by type
are walked whatever their exposure. A `kind: :unknown` node is the hit itself
(path `[]` below its parent) when it is map-like, and opaque otherwise. A
`:type_ref` to a NewType over a custom type (an `:unknown` definition) is
checked with the constraints on the ref, the ones given where it's used, as
Ash calls the callbacks. Each named type and resource is visited once, so
recursive types terminate. `lookups` needs `:resource_lookup` and
`:type_lookup` from a decorated manifest (an `%AshRpc.Runtime{}` works).
`find_untyped_root(roots, lookups)` runs it over `{root, type, tag}` roots in
order and returns `{[root | path], node, tag}` for the first hit; the
decorator and extensions build their roots and errors on it.

Both are the generic walk `find_type(type, lookups, match, opts \\ [])` with
the untyped test as the matcher. Extensions use it for their own type rules.
`match` is a function of the node, tested on every node (the root included)
before its children, so the walk never descends into a matching node: a
resource matcher finds the resource, not a union in its fields. It returns
`{:match, path, node}` or `nil`. `cycles: :skip` (the default) skips a named
type already walked, as above; `cycles: :report` returns `{:cycle, path, ref}`
for a `:type_ref` to a named type that is being walked on the current branch
(`[:children, []]` for `AshRpc.Test.TreeNode`). A named type used on two
separate branches is not a cycle. Resources are walked once, so recursion
through a resource (named type A → resource → A) is reported only when the
walk meets A first; a matcher that matches resources never meets it
(`test/introspection_test.exs` "recursion through a resource is reported only
when entered at the named type"). `find_type_root(roots, lookups, match,
opts \\ [])` returns `{:match | :cycle, [root | path], node, tag}`.

The decorator checks only wire entrypoints (those `entrypoint/1` returns a
struct for), root by root, inputs first, through the public
`Decorator.check_untyped_structs!(manifest_entrypoint, %AshRpc.Entrypoint{},
lookups, opts \\ [])`. It returns `:ok` or raises the error, and an extension
calls it for entrypoints it serves off the wire (ones `entrypoint/1` returns
`nil` for), with `lookups` from the decorated manifest
(`AshRpc.Manifest.resource_lookup/1`, `type_lookup/1`). Its `hint:` option is
extra text for an undeclared custom type: a string, or a function of the
module returning a string or `nil`. `decorate/3` passes its
`custom_type_fields_hint:` option, else the mapping source's
`custom_type_fields_hint/1` when the source exports it, and no hint
otherwise. The roots:

| Root | Checked when |
|---|---|
| `argument :name` / `attribute :name` | Every input; `attribute` for an accepted attribute of a non-generic action |
| `returns` | Always (`nil` for CRUD actions) |
| `<Resource> records` | Non-generic actions |
| `metadata :name` | Metadata fields in `exposed_metadata_fields` |

The message names the wire name, resource and action, the verb (`accepts` for
inputs, `returns` otherwise), the struct (its `instance_of`, "`:struct`
without constraints", plus the NewType it came through) and the path joined
with ` → ` (`returns → session`). Then it lists the alternatives: an
`Ash.TypedStruct`, a NewType over `:struct` with `fields`, `instance_of` an
Ash resource, or an unconstrained `:map` converted in the action. An Ash-type
`instance_of` gets "use it as the type" first.

For an undeclared custom type the message reads "returns an undeclared custom
type, `Mod`, at `returns`.", says that its values are maps or structs but no
fields are declared for it, so their keys have no client names, and ends with
the hint after a blank line when there is one. No alternatives are listed,
and `struct_module` is `nil` (the message and `path` name the module). A hint
applies only to this branch.

Extensions word their own errors with `UntypedStructError.details/3`
(`details(type, path, hint: hint)`; `details/2` is the same without a hint).
`allow_resource?: false` drops the "`instance_of` an Ash resource"
alternative, for places that don't accept resources.

Tests: `test/untyped_struct_test.exs` "decoration rejects untyped structs",
"decoration rejects undeclared map-like custom types",
"check_untyped_structs!/4", "UntypedStructError", "typed and explicitly
untyped shapes stay allowed";
`test/introspection_test.exs` "untyped structs", "find_type/4".

## The Output Formatter Is Fixed at Decoration

`AshRpc.Runtime.new/2` reads the output formatter and vocabulary from
`custom.ash_rpc`; nothing reads them from application config at request time.
Collisions in any reverse map or vocabulary scope raise
`NameCollisionError` naming the scope. To vary the formatter in a test:

`AshRpc.Manifest.redecorate/2` re-runs the decorator with the stored mapping
source; if that mapping source isn't loaded it raises `ArgumentError`
(`test/manifest/redecorate_test.exs`). See [testing](../testing.md) for the
recipe (`redecorate/2` or `ManifestBuilder.build/1` plus the `manifest:`
option), and [pipeline](pipeline.md) for how the runtime threads the result through a
request.
