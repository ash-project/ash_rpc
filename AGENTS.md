<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# AshRpc - AI Assistant Guide

## Project Overview

**AshRpc** is a client-agnostic RPC runtime for Ash. It turns a wire request
(`%{"action" => …, "input" => …, "fields" => …}`) into an Ash action call
and returns a client-formatted response map. It has no code generation and no
DSL: an extension builds an `Ash.Info.Manifest`, decorates it with ash_rpc,
and mounts an endpoint.

**Key Features**: manifest decoration with client-facing names, a four-stage
request pipeline, type-driven field selection (relationships, calculations,
embedded resources, unions, typed maps), nested relationship query options,
load restrictions, action metadata, native input validation, a pluggable
error protocol and handlers, and optional Plug and Phoenix channel transports

## 🚨 Critical Development Rules

### Rule 1: This Library Has Consumers
ash_rpc is a library that extensions build on. Consumers delegate to `AshRpc`
public functions, and some of their tests call `AshRpc` internals directly.
A function with no callers in this repo is not necessarily dead code.

| ❌ Wrong | ✅ Correct |
|----------|------------|
| Rename or remove a public `AshRpc*` function after checking only this repo | Check known consumers for usages first, and treat it as a breaking change |
| Treat ash_rpc's tests as the full compatibility check | Run the test suites of known consumers too, when they're available locally |
| Change a consumer's code without being asked | Report the needed consumer changes, and leave any edits you were asked to make uncommitted |

### Rule 2: No References to Consumers
Nothing under `lib/`, `test/` or `agent-docs/` (and nothing in this file) may
name an extension built on ash_rpc. Anything client-specific (client-language
names, generated-client wording) belongs in a `MappingSource`, a `Profile`, or
the extension itself. When you need a neutral default, put it in a profile
callback the way `stale_client_hint/0` does.

### Rule 3: The Runtime Reads the Manifest, Not Ash
Runtime code gets action, resource and type shape only from `AshRpc.Runtime`
lookups (`manifest.custom.ash_rpc.lookups`), through
`AshRpc.Introspection.get_action!(runtime, resource, action)`. Do not add
`Ash.Resource.Info.action/2` calls or global/app-env reads in `lib/ash_rpc/`.
Everything a request needs travels on `Request.runtime`.

### Rule 4: Debug With Tests
Write a failing test in `test/` instead of debugging one-off in a shell. The
fixtures (`AshRpc.Test.*`) only compile in `:test` (`elixirc_paths`).

## Essential Workflows

### Wiring an Extension (what a consumer does)
```elixir
# 1. Mapping source: compile-time client names (called only during decoration)
defmodule MyExt.MappingSource do
  @behaviour AshRpc.MappingSource
  def output_formatter, do: :camel_case
  def exposed_resource?(resource), do: ...
  def field_names(_resource), do: %{}          # overrides only
  def argument_names(_resource, _action), do: %{}
  def type_field_names(_type), do: nil
  def custom_type_fields(_type), do: nil       # optional: field specs for a custom type
  def custom_type_fields_hint(_type), do: nil  # optional: text for the undeclared-type error
  def entrypoint(%Ash.Info.Manifest.Entrypoint{} = e),
    do: %AshRpc.Entrypoint{name: "...", resource: e.resource, action: e.action.name}
end

# 2. Build and decorate the manifest
{:ok, manifest} = Ash.Info.Manifest.Generator.generate(otp_app: :my_app, action_entrypoints: [...])
manifest = AshRpc.Manifest.Decorator.decorate(manifest, MyExt.MappingSource)

# 3. Profile: runtime configuration
defmodule MyExt.RpcProfile do
  use AshRpc.Profile, manifest: MyExt.Manifest   # resolved via AshRpc.Manifest.fetch!/1
end

# 4. Transport
AshRpc.run_action(MyExt.RpcProfile, conn_or_socket_or_context, params)
AshRpc.Plug.run(conn, MyExt.RpcProfile)           # 200, JSON body (raises if untyped data can't be encoded)
use AshRpc.Channel, profile: MyExt.RpcProfile     # "run" / "validate" events
```

`test/support/mapping_source.ex`, `manifest_builder.ex` and `profile.ex` are a
complete minimal version of this wiring.

### Wire Contract
Request params (keys are the output formatter's client names, from the `vocabulary`, apart from `input` and `identity`):
`action`, `input`, `fields`, `identity`, `getBy`, `filter`, `sort`, `page`,
`tenant`, `metadataFields`.

Responses are always maps and never tuples: `%{"success" => true, "data" => …}` or
`%{"success" => false, "errors" => [...]}`. Key casing comes from the output
formatter.

## Codebase Navigation

### Key File Locations

| Purpose | Location |
|---------|----------|
| **Public API** | `lib/ash_rpc.ex` (`run_action/4`, `validate_action/4`, `error_response/3`, `failure_response/3`) |
| **Behaviours** | `lib/ash_rpc/profile.ex`, `lib/ash_rpc/mapping_source.ex`, `lib/ash_rpc/error_handler.ex`, `lib/ash_rpc/default_error_handler.ex` (the default `error_handler/1` result) |
| **Runtime / entrypoint / context / request** | `lib/ash_rpc/runtime.ex`, `entrypoint.ex`, `context.ex`, `request.ex` |
| **Manifest decoration** | `lib/ash_rpc/manifest/decorator.ex` (pure: manifest in, manifest out) |
| **Declared custom types (decoration pass)** | `lib/ash_rpc/manifest/custom_types.ex` (collect, definitions, fixpoint, staging; called from `decorate/3`) |
| **`custom.ash_rpc` readers, lookups, `redecorate/2`** | `lib/ash_rpc/manifest.ex`, `lib/ash_rpc/manifest/custom.ex` (reverse maps, plus the forward `field_names/1`, `type_field_names/1`, `type_member_names/1`, `entrypoint_metadata_field_names/1`) |
| **Name collisions / untyped structs** | `lib/ash_rpc/manifest/name_collision_error.ex`, `lib/ash_rpc/manifest/untyped_struct_error.ex` |
| **Pipeline orchestration** | `lib/ash_rpc/pipeline.ex` |
| **Manifest introspection (`get_action!/3`, `find_untyped_struct/2`)** | `lib/ash_rpc/introspection.ex` |
| **Native validation (`validate_action`)** | `lib/ash_rpc/validation.ex` |
| **Field processing (entry point)** | `lib/ash_rpc/requested_fields_processor.ex` (delegator) |
| **Client name → atom** | `lib/ash_rpc/field_processing/atomizer.ex` |
| **Type-driven field selection** | `lib/ash_rpc/field_processing/field_selector.ex`, `field_selector/validation.ex` |
| **Result extraction** | `lib/ash_rpc/result_processor.ex`, `lib/ash_rpc/field_extractor.ex` |
| **Value formatting** | `lib/ash_rpc/value_formatter.ex` (`input_formatter.ex` delegates to it; the pipeline formats output through it directly) |
| **Field-name casing** | `lib/ash_rpc/field_formatter.ex`, `lib/ash_rpc/case.ex` |
| **Client-name resolution** | `lib/ash_rpc/client_names.ex` |
| **Filter/sort name rewriting** | `lib/ash_rpc/filter_input.ex` |
| **Load-restriction normalization** | `lib/ash_rpc/load_restrictions.ex` (`normalize/1` in `parse_request`, `check!/2` from the field selector) |
| **Error protocol + impls** | `lib/ash_rpc/error.ex` |
| **Error pipeline** | `lib/ash_rpc/errors.ex` (Ash errors), `error_builder.ex` (pipeline reasons), `error_formatter.ex` |
| **Client names in error `path` / `fields`** | `lib/ash_rpc/client_path.ex` (walks a path through the decorated manifest) |
| **Transports (optional deps)** | `lib/ash_rpc/plug.ex`, `lib/ash_rpc/channel.ex` |

### Test Fixtures (`test/support/`)

| Fixture | Purpose |
|---------|---------|
| `domain.ex` | `AshRpc.Test.Domain`: every fixture resource |
| `mapping_source.ex` | `AshRpc.Test.MappingSource`: exposure list, name overrides, row opts → `%AshRpc.Entrypoint{}` |
| `manifest_builder.ex` | Wire entrypoints in `@entrypoints`. `manifest/0` is cached, `build/1` builds fresh, `generate!/1` returns an undecorated manifest |
| `profile.ex` | `AshRpc.Test.Profile` |
| `endpoint.ex` | Phoenix socket/endpoint/channel for channel tests |
| `error_cases.ex` | One reason per `ErrorBuilder` clause, for the golden test |

Resources, embedded types, calculations and changes are listed in
`agent-docs/testing.md`. To add a wire action for a test, add a row to
`@entrypoints` in `manifest_builder.ex`; row opts set `%AshRpc.Entrypoint{}` fields.

## Command Reference

```bash
mix test                          # Run all tests (do NOT prefix with MIX_ENV=test)
mix test test/run_action_test.exs # One file
mix check                         # compiler, format, credo --strict, dialyzer, sobelow, reuse lint, tests, …
mix check --format agent          # Parseable output
mix check -o credo -o ex_unit     # Narrow while iterating
mix usage_rules.sync              # Regenerate the usage-rules block of this file
```

`.tool-versions` pins Elixir/Erlang, so plain `mix` works. The `reuse` check runs
`pipx run reuse lint`, and every new file needs an SPDX header. Copy the header
from an existing file of the same kind. Formats without comment syntax need a
`<file>.license` sidecar (see `mix.lock.license`).

## Documentation Index

### Core Files

| File | Purpose |
|------|---------|
| [troubleshooting.md](agent-docs/troubleshooting.md) | Symptom → cause → fix, and how to reproduce a problem in a test |
| [development-workflows.md](agent-docs/development-workflows.md) | Changing the pipeline, adding wire actions, fixtures and error reasons, consumer compatibility |
| [testing.md](agent-docs/testing.md) | Suite layout, `ManifestBuilder`, varying the manifest, test patterns, full fixtures table |

### Feature Docs

| Working On | See Documentation | Test Files |
|------------|-------------------|------------|
| **MappingSource, decoration, entrypoints, client names, formatters** | [features/decoration.md](agent-docs/features/decoration.md) | `test/manifest/decorator_test.exs`, `test/manifest/custom_test.exs`, `test/manifest/custom_types_test.exs`, `test/custom_type_fields_test.exs`, `test/manifest/redecorate_test.exs`, `test/untyped_struct_test.exs`, `test/entrypoint_test.exs`, `test/runtime_test.exs`, `test/profile_test.exs` |
| **Pipeline stages, validation, transports, tenant, filter/sort/page, get actions** | [features/pipeline.md](agent-docs/features/pipeline.md) | `test/run_action_test.exs`, `test/validation_test.exs`, `test/context_test.exs`, `test/plug_test.exs`, `test/channel_test.exs`, `test/multitenancy_test.exs`, `test/filter_sort_test.exs`, `test/get_actions_test.exs` |
| **Field selection, calculations, aggregates, nested query options, unions, load restrictions** | [features/field-selection.md](agent-docs/features/field-selection.md) | `test/field_selector_test.exs`, `test/untyped_struct_test.exs`, `test/typed_field_selection_test.exs`, `test/calculations_test.exs`, `test/aggregates_test.exs`, `test/nested_query_opts_test.exs`, `test/load_restrictions_test.exs`, `test/result_output_test.exs`, `test/result_processor_test.exs`, `test/type_classification_test.exs`, `test/union_output_test.exs`, `test/keyword_tuple_test.exs`, `test/typed_struct_test.exs`, `test/generic_returns_test.exs`, `test/embedded_resources_test.exs` |
| **Value/input formatting, declared-only output, union input, unconstrained maps, name mapping, client-name resolution** | [features/formatting.md](agent-docs/features/formatting.md) | `test/value_formatter_test.exs`, `test/declared_output_test.exs`, `test/field_formatter_test.exs`, `test/field_name_translation_test.exs`, `test/union_input_test.exs`, `test/unconstrained_map_test.exs`, `test/complex_input_test.exs`, `test/client_names_test.exs`, `test/filter_input_test.exs` |
| **Action metadata** | [features/action-metadata.md](agent-docs/features/action-metadata.md) | `test/action_metadata_test.exs` |
| **Errors, handlers, wire error shape** | [features/errors.md](agent-docs/features/errors.md) | `test/errors_test.exs`, `test/error_protocol_test.exs`, `test/error_builder_golden_test.exs`, `test/error_formatter_test.exs`, `test/error_redaction_test.exs` |

## Key Architecture Concepts

### Compile Time vs Runtime
- **Decoration (compile time, extension-owned):** `Decorator.decorate/3` calls the
  `MappingSource` once and precomputes everything under `manifest.custom.ash_rpc`.
  That includes the output formatter, wire `entrypoints` keyed by name, forward
  and reverse client names (resources, calculation arguments, every type tree
  including inline types, entrypoint metadata), the request `vocabulary`,
  expected input keys, return classification and `lookups`.
- **Runtime:** `AshRpc.Runtime.new(profile, opts)` reads that decoration once
  per request. The runtime never calls the mapping source. The one exception is
  `type_field_names/1`, the fallback for types missing from the type lookup
  or carrying no decorated overrides.
- Declared custom types: a custom `use Ash.Type` module for which
  `custom_type_fields/1` (or `decorate/3`'s `custom_type_fields:` option)
  returns field specs gets a named `kind: :map` definition in
  `manifest.types` (`custom.ash_rpc.custom_type: true`), and every use becomes
  a `:type_ref` to it. Fields are per module; the runtime treats it as a typed
  map. `:extra_types` declares types used only outside the manifest.
- Client names are resolved only by exact lookup (`AshRpc.ClientNames`);
  nothing parses a client string with a formatter. Extensions decorate types
  that never enter the manifest with `Decorator.decorate_type/4` (passing
  the same `custom_type_fields:` option as `decorate/3`).
- `Runtime.new/2` raises `ArgumentError` ("has no custom.ash_rpc decoration")
  when it gets an undecorated manifest.
- Decoration raises `AshRpc.Manifest.UntypedStructError` when a wire
  entrypoint's inputs, return, records or exposed metadata reach a struct type
  with no field types: `fields: nil`, or `fields: []` without an `instance_of`
  that is an Ash type or resource (none, or a plain `defstruct`). Only an
  empty TypedStruct (or another Ash type) passes with `fields: []`.
  It raises the same error for a map-like custom type (`storage_type :map`
  or `composite?/1` true, with the constraints where it is used) that has no
  declared fields; the mapping source's optional `custom_type_fields_hint/1`
  (or `decorate/3`'s `custom_type_fields_hint:` option: a string, or a
  function of the module returning a string or `nil`) is appended to the
  message. Declared custom types are walked through their
  definitions. Other custom types are opaque.
  Extensions check entrypoints they serve themselves with
  `Decorator.check_untyped_structs!/4` (`hint:` option, same types), and their
  own types with `AshRpc.Introspection.find_untyped_struct/2` (or
  `find_untyped_root/2` over labelled roots). `map_like_custom_type?/2` is
  the walk's test for a `kind: :unknown` node, for extensions' own checks.

### RPC Pipeline (Four Stages)
Entry points are `AshRpc.run_action/4` and `AshRpc.validate_action/4` (profile, conn/socket/`%AshRpc.Context{}`, params, opts).
1. **parse_request**: resolve the `AshRpc.Entrypoint` (from `params["action"]`
   or the `entrypoint:` option), apply the `tenant` param, validate params,
   atomize and select fields, build the extraction template
2. **execute_ash_action**: run the Ash query/changeset/generic action
3. **process_result**: apply field selection using the template
4. **format_output**: format values and keys for the client

`validate_action` stops after stage 1 and runs `AshRpc.Validation`.
Validation is native (no AshPhoenix). Missing inputs produce `required`,
bad argument casts produce `invalid_argument`, and atomic validations on
update/destroy only run during `run_action`.

### Action Shape Contract
Downstream stages operate on `%Ash.Info.Manifest.Action{}`: `inputs` (arguments and
accepted attributes combined, each with a resolved `%Ash.Info.Manifest.Type{}`), `returns`,
`pagination` (`:countable?`), and resolved `metadata`. Raw-Ash fields
(`arguments`, `accept`, `constraints`, …) are **not** present.

### Errors
`AshRpc.Errors.to_errors/6` converts errors to an Ash error class, unwraps them,
and applies the `AshRpc.Error` protocol. It then applies `show_raised_errors?/1`
and policy breakdowns (`show_policy_breakdowns?/0`), the resource-level handler,
and finally the profile's `error_handler/1` for the domain. A handler that returns
`nil` drops the error. Pipeline reasons such as
`{:action_not_found, …}` become error maps in `ErrorBuilder`; a non-map reason
with no `ErrorBuilder` clause becomes `internal_error` with an `errorId`, the
term only logged server-side (a map or struct becomes `unknown_error`, equally
without the term). Request errors that
a stale client could cause carry `details.hint` from the profile's `stale_client_hint/0`,
and `action_not_found` carries `details.suggestion` from `action_not_found_suggestion/0`.
Exceptions raised during `run_action`/`validate_action` are logged with their
stacktrace and returned as `unknown_error`.

### Core Patterns
- **Type-driven dispatch**: `FieldSelector` and `ValueFormatter` both recurse on `{type, constraints}`
- **Strict exposure**: selecting through a relationship to a resource the mapping source doesn't expose is `unknown_field`. Embedded resources the source doesn't expose are still decorated, under formatter-only names and `exposed: false`, so they stay selectable as attributes and union members. So are unexposed domain resources an entrypoint takes as a struct input, so their input keys resolve; relationships to them stay `unknown_field`
- **Untyped data**: a value whose declared type has no shape
  (`AshRpc.Introspection.untyped_data_type?/2`: an unconstrained `:map`,
  `Ash.Type.Term`, or an array of either) is sent exactly as produced, as a
  generic return and nested in field-selected typed containers. Jason encodes
  it or the encode fails. A typed resource selected whole is still normalized,
  its untyped attributes included. Accepted side effects: an encode failure
  logs `inspect(value)` (private attributes not marked `sensitive?` included),
  an `Ash.Union` inside it encodes as its value instead of `{member: value}`,
  and `run_action/4` callers get raw structs
- **Typed output**: typed maps and structs (keywords and tuples included) emit only their declared fields on every output path, under decorated names; undeclared keys are dropped and struct values go through `Map.from_struct/1`
- **Values formatted without extraction** (`ValueFormatter.format/5` on `:output`): scalar structs (`DateTime`, `Duration`, `Decimal`, …) at typed scalar positions get the extracted wire shape, resource structs keep only their manifest fields (`nil` for unloaded and forbidden values, `%{}` for a resource not in the manifest), and a raw `%Ash.Union{}` becomes `{member: value}`. Untyped data is unchanged
- **Tenant param**: a `tenant` request param overrides the transport tenant (`conn` or `socket.assigns[:ash_tenant]`)
- **Optional transports**: `AshRpc.Plug` / `AshRpc.Channel` are wrapped in `Code.ensure_loaded?/1` and only exist when plug/phoenix are present. `AshRpc.Context.from_source/1` follows the same rule

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| "has no custom.ash_rpc decoration" `ArgumentError` | Raw `Ash.Info.Manifest` passed to the runtime | Decorate with `AshRpc.Manifest.Decorator.decorate/3` (or use the fixture `ManifestBuilder`) |
| `AshRpc.Manifest.NameCollisionError` | Two fields/args map to the same client name | Fix `field_names` / `argument_names` overrides |
| `AshRpc.Manifest.UntypedStructError` | A wire entrypoint accepts or returns a `:struct` without `fields` (a plain `defstruct` `instance_of`, `instance_of` an Ash type, or no constraints), or with `fields: []` and no Ash-type `instance_of` (none, or a plain one), anywhere in its exposed graph, including inside a declared custom type's fields; or a map-like custom type (`storage_type :map` or composite) without declared fields ("an undeclared custom type") | Use an `Ash.TypedStruct`, a NewType over `:struct` with `fields`, `instance_of` a resource, or an unconstrained `:map` built in the action. For an Ash-type `instance_of`, use the type itself; in a declared custom type, change the field. For an undeclared custom type, declare its fields (`custom_type_fields/1`) |
| `Protocol.UndefinedError` "Jason.Encoder not implemented for X" (a 500 from `AshRpc.Plug`) | Untyped data (an unconstrained `:map` / `:term` return, attribute or field) holds a struct, tuple, keyword list, `Duration` or `ForbiddenField`; it is sent as produced | Convert it in the action, or declare the type (the resource, an `Ash.TypedStruct`, a typed map). The error message `inspect`s the value, so mark secret attributes `sensitive?: true` |
| Formatter change in a test has no effect | The output formatter is fixed at decoration time | `ManifestBuilder.build(output_formatter: …)` or `AshRpc.Manifest.redecorate/2`, then pass `manifest:` |
| Test sees unexpected data/state | `ManifestBuilder.manifest/0` is cached in `:persistent_term` | Use `build/1` for a variant manifest. Don't mutate the cached one |
| `action_not_found` | Wire name not in `@entrypoints`, or `entrypoint/1` returned `nil` | Add it to `manifest_builder.ex` |
| `unknown_field` through a relationship | Destination resource not exposed | Add it to `@exposed` in the test mapping source (not `Secret`, which stays unexposed on purpose) |
| `unknown_input` | An input key that isn't one of the action's client names (a misspelling, another casing, or a private `public? false` argument), or a nested key that isn't a client name of its type (`path` locates it); raised by ash_rpc before Ash runs | Send the client name from the manifest, or drop the key |
| `unknown_field` / sort or filter error for a correctly spelled name | The name is in a non-client casing (e.g. `view_count` under `:camel_case`) | Send the client name; names are matched exactly |
| `UndefinedFunctionError` on `AshRpc.Plug` / `AshRpc.Channel` | plug/phoenix not in the consumer's deps | They're optional deps. Add them in the consumer |
| `invalid_query_opts` | Query envelope on a non-relationship or to-one field, `args` mixed with query opts, or `page` mixed with bare `limit`/`offset` | Use the envelope only on has_many/many_to_many; pick `page` or `limit`/`offset` |
| `filter_not_supported` / `sort_not_supported` | `details.reason` `disabled`: the entrypoint sets `enable_filter?`/`enable_sort?: false`. `unsupported`: the param is on a non-list action (a `get?`/`get_by` entrypoint or a non-read action) or the relationship isn't filterable/sortable | Remove the param, or flip the entrypoint flag |
| `pagination_not_supported` | `page` on a non-list action or an action without pagination, or nested `page` on a relationship whose read action has no pagination | Add pagination to that read action, or use bare `limit`/`offset` |
| `load_not_allowed` / `load_denied` | Requested field is outside the entrypoint's `{:allow, …}` list, or inside its `{:deny, …}` list | Change `load_restrictions` on the entrypoint (see `agent-docs/features/field-selection.md`) |
| `invalid_union_input` "must be a map" | Bare value for a union input | Wrap it: `%{"member_name" => value}` |
| `invalid_union_input` "does not contain any valid member key" | Map has no key naming a member | Use a member name from `vars.expectedMembers` |
| `invalid_union_input` "contains multiple member keys" | More than one member key in the map | Send exactly one member key |
| `AshRpc.RuntimeBoundaryTest` failure | Runtime code under `lib/ash_rpc/` calls `Ash.Resource.Info`, `Ash.DataLayer` or reads the app env (Rule 3) | Read shape from `runtime` lookups; allowlist only calls that classify runtime values, with a reason |
| `reuse lint` failure | New file without an SPDX header | Add the header (or a `.license` sidecar) |

## Safety Checklist

- ✅ `mix check` passes (not just `mix test`)
- ✅ Public API changes checked and tested against known consumers
- ✅ No consumer names in `lib/`, `test/`, `agent-docs/` or this file
- ✅ Runtime code reads shape from `runtime` lookups only (`test/runtime_boundary_test.exs`)
- ✅ New files carry SPDX headers
- ✅ Regression test written before the fix

---

<!-- usage-rules-start -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

@deps/ash/usage-rules.md
<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
@deps/ash/usage-rules/actions.md
<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
@deps/ash/usage-rules/aggregates.md
<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
@deps/ash/usage-rules/authorization.md
<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
@deps/ash/usage-rules/calculations.md
<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
@deps/ash/usage-rules/code_interfaces.md
<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
@deps/ash/usage-rules/code_structure.md
<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
@deps/ash/usage-rules/data_layers.md
<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
@deps/ash/usage-rules/exist_expressions.md
<!-- ash:exist_expressions-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
@deps/ash/usage-rules/query_filter.md
<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
@deps/ash/usage-rules/querying_data.md
<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
@deps/ash/usage-rules/relationships.md
<!-- ash:relationships-end -->
<!-- ash:signals-start -->
## ash:signals usage
@deps/ash/usage-rules/signals.md
<!-- ash:signals-end -->
<!-- ash:temporal-start -->
## ash:temporal usage
@deps/ash/usage-rules/temporal.md
<!-- ash:temporal-end -->
<!-- ash:testing-start -->
## ash:testing usage
@deps/ash/usage-rules/testing.md
<!-- ash:testing-end -->
<!-- ex_check-start -->
## ex_check usage
_ex_check_

@deps/ex_check/usage-rules.md
<!-- ex_check-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

@deps/usage_rules/usage-rules.md
<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
@deps/usage_rules/usage-rules/elixir.md
<!-- usage_rules:elixir-end -->
<!-- usage-rules-end -->
