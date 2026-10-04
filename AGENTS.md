<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# AshRpc - AI Assistant Guide

## Project Overview

**AshRpc** is a client-agnostic RPC runtime for Ash. It turns a wire request
(`%{"action" => …, "input" => …, "fields" => …}`) into an Ash action call
and returns a client-formatted response map. It has no code generation and no
DSL: extensions such as ash_typescript build an `Ash.Info.Manifest`, decorate it
with ash_rpc, and mount an endpoint.

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
Nothing under `lib/` may name an extension built on ash_rpc. Anything
client-specific (TypeScript names, generated-client wording) belongs in a
`MappingSource`, a `Profile`, or the extension itself. When you need a neutral
default, put it in a profile callback the way `stale_client_hint/0` does.

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
  def input_formatter, do: :camel_case
  def output_formatter, do: :camel_case
  def exposed_resource?(resource), do: ...
  def field_names(_resource), do: %{}          # overrides only
  def argument_names(_resource, _action), do: %{}
  def type_field_names(_type), do: nil
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
AshRpc.Plug.run(conn, MyExt.RpcProfile)           # always 200, JSON body
use AshRpc.Channel, profile: MyExt.RpcProfile     # "run" / "validate" events
```

`test/support/mapping_source.ex`, `manifest_builder.ex` and `profile.ex` are a
complete minimal version of this wiring.

### Wire Contract
Request params (keys pass through the input formatter, apart from `input` and `identity`):
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
| **Behaviours** | `lib/ash_rpc/profile.ex`, `lib/ash_rpc/mapping_source.ex`, `lib/ash_rpc/error_handler.ex` |
| **Runtime / entrypoint / context / request** | `lib/ash_rpc/runtime.ex`, `entrypoint.ex`, `context.ex`, `request.ex` |
| **Manifest decoration** | `lib/ash_rpc/manifest/decorator.ex` (pure: manifest in, manifest out) |
| **`custom.ash_rpc` readers, lookups, `redecorate/2`** | `lib/ash_rpc/manifest.ex`, `lib/ash_rpc/manifest/custom.ex` |
| **Name collisions** | `lib/ash_rpc/manifest/name_collision_error.ex` |
| **Pipeline orchestration** | `lib/ash_rpc/pipeline.ex` |
| **Manifest introspection (`get_action!/3`)** | `lib/ash_rpc/introspection.ex` |
| **Native validation (`validate_action`)** | `lib/ash_rpc/validation.ex` |
| **Field processing (entry point)** | `lib/ash_rpc/requested_fields_processor.ex` (delegator) |
| **Client name → atom** | `lib/ash_rpc/field_processing/atomizer.ex` |
| **Type-driven field selection** | `lib/ash_rpc/field_processing/field_selector.ex`, `field_selector/validation.ex` |
| **Load restrictions** | `lib/ash_rpc/load_restrictions.ex` (checked from `field_selector.ex`) |
| **Result extraction** | `lib/ash_rpc/result_processor.ex`, `lib/ash_rpc/field_extractor.ex` |
| **Value formatting** | `lib/ash_rpc/value_formatter.ex` (`input_formatter.ex` delegates to it; the pipeline formats output through it directly) |
| **Field-name casing** | `lib/ash_rpc/field_formatter.ex`, `lib/ash_rpc/case.ex` |
| **Error protocol + impls** | `lib/ash_rpc/error.ex` |
| **Error pipeline** | `lib/ash_rpc/errors.ex` (Ash errors), `error_builder.ex` (pipeline reasons), `error_formatter.ex` |
| **Transports (optional deps)** | `lib/ash_rpc/plug.ex`, `lib/ash_rpc/channel.ex` |

### Test Fixtures (`test/support/`)

| Fixture | Purpose |
|---------|---------|
| `domain.ex` | `AshRpc.Test.Domain` (Author, Post, Secret) |
| `post.ex`, `author.ex`, `secret.ex` | ETS resources. `Secret` is deliberately **not exposed** |
| `post_settings.ex`, `post_stats.ex` | Embedded resource / typed map with field-name overrides |
| `mapping_source.ex` | `AshRpc.Test.MappingSource`: exposure, `isActive`, `body`, `wordCount1` overrides |
| `manifest_builder.ex` | Wire entrypoints (`list_posts`, `create_post`, `word_count`, …). `manifest/0` is cached, `build/1` builds fresh |
| `profile.ex` | `AshRpc.Test.Profile` |
| `endpoint.ex` | Phoenix socket/endpoint for channel tests |

To add a wire action for a test, add it to `@entrypoints` in `manifest_builder.ex`.

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

## Key Architecture Concepts

### Compile Time vs Runtime
- **Decoration (compile time, extension-owned):** `Decorator.decorate/3` calls the
  `MappingSource` once and precomputes everything under `manifest.custom.ash_rpc`.
  That includes formatters, wire `entrypoints` keyed by name, client field/argument
  names, expected input keys, return classification and `lookups`.
- **Runtime:** `AshRpc.Runtime.new(profile, opts)` reads that decoration once
  per request. The runtime never calls the mapping source. The one exception is
  `type_field_names/1`, the fallback for types missing from the type lookup.
- `Runtime.new/2` raises `ArgumentError` ("has no custom.ash_rpc decoration")
  when it gets an undecorated manifest.

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
`{:action_not_found, …}` become error maps in `ErrorBuilder`. Request errors that
a stale client could cause carry `details.hint` from the profile's `stale_client_hint/0`.

### Core Patterns
- **Type-driven dispatch**: `FieldSelector` and `ValueFormatter` both recurse on `{type, constraints}`
- **Strict exposure**: selecting through a relationship to a resource the mapping source doesn't expose is `unknown_field`
- **Tenant param**: a `tenant` request param overrides the transport tenant (`conn` or `socket.assigns[:ash_tenant]`)
- **Optional transports**: `AshRpc.Plug` / `AshRpc.Channel` are wrapped in `Code.ensure_loaded?/1` and only exist when plug/phoenix are present. `AshRpc.Context.from_source/1` follows the same rule

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| "has no custom.ash_rpc decoration" `ArgumentError` | Raw `Ash.Info.Manifest` passed to the runtime | Decorate with `AshRpc.Manifest.Decorator.decorate/3` (or use the fixture `ManifestBuilder`) |
| `AshRpc.Manifest.NameCollisionError` | Two fields/args map to the same client name | Fix `field_names` / `argument_names` / `type_field_names` overrides |
| Formatter change in a test has no effect | Formatters are fixed at decoration time | `ManifestBuilder.build(output_formatter: …)` or `AshRpc.Manifest.redecorate/2`, then pass `manifest:` |
| Test sees unexpected data/state | `ManifestBuilder.manifest/0` is cached in `:persistent_term` | Use `build/1` for a variant manifest. Don't mutate the cached one |
| `action_not_found` | Wire name not in `@entrypoints`, or `entrypoint/1` returned `nil` | Add it to `manifest_builder.ex` |
| `unknown_field` through a relationship | Destination resource not exposed | Add it to `@exposed` in the test mapping source (not `Secret`, which stays unexposed on purpose) |
| `UndefinedFunctionError` on `AshRpc.Plug` / `AshRpc.Channel` | plug/phoenix not in the consumer's deps | They're optional deps. Add them in the consumer |
| `reuse lint` failure | New file without an SPDX header | Add the header (or a `.license` sidecar) |

## Safety Checklist

- ✅ `mix check` passes (not just `mix test`)
- ✅ Public API changes checked and tested against known consumers
- ✅ No consumer names in `lib/`
- ✅ Runtime code reads shape from `runtime` lookups only
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
