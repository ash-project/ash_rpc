<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Request Pipeline

How a wire request becomes an Ash call and a client-formatted response: entry
points, the threaded `AshRpc.Runtime`, the transport-independent
`AshRpc.Context`, the four stages, native validation, transports, the `tenant`
param, top-level `filter`/`sort`/`page`, and get-style reads and identities.

What the decoration step puts in the manifest (entrypoints, client names,
formatters) is in [decoration](decoration.md). Field selection inside stage 1
is in [field selection](field-selection.md), value formatting in stage 4 is in
[formatting](formatting.md), and error maps are in [errors](errors.md).

## Entry points

| Function | Purpose |
|----------|---------|
| `AshRpc.run_action(profile, source, params, opts \\ [])` | Full four-stage run |
| `AshRpc.validate_action(profile, source, params, opts \\ [])` | Stage 1 plus native validation; nothing executes |
| `AshRpc.error_response(profile, reason, opts \\ [])`, `AshRpc.failure_response(profile, errors, opts \\ [])` | Failure envelopes for a pipeline reason / prebuilt error maps (see [errors](errors.md)) |

- `source` is a `Plug.Conn`, a `Phoenix.Socket` or an `%AshRpc.Context{}`.
  `AshRpc.Context.from_source/1` turns it into a context.
- `opts` (`@type opts` in `lib/ash_rpc.ex`):
  - `manifest:` a decorated `%Ash.Info.Manifest{}` that replaces the profile's
    manifest for this call (e.g. from `AshRpc.Manifest.redecorate/2`).
  - `entrypoint:` an `%AshRpc.Entrypoint{}` used instead of looking up
    `params["action"]`. This is how an extension runs a preset query that has
    no wire action (see `preset_fields` in [decoration](decoration.md)).
- Responses are always maps, never tuples: `%{"success" => true, "data" => …}`
  or `%{"success" => false, "errors" => [...]}`. Key casing comes from the
  output formatter. Mutations with exposed metadata add a `"metadata"` key
  ([action metadata](action-metadata.md)).
- Both functions `rescue` and return the exception as a failure response, so a
  crash inside the pipeline is still a wire error (`test/run_action_test.exs`
  "run_action and validate_action turn pipeline exceptions into wire errors").

## `AshRpc.Runtime`

`AshRpc.Runtime.new(profile, opts \\ [])` resolves everything a request needs
once, and the struct is threaded through every stage on `Request.runtime`.
Runtime code never reads globals or app env (see `AGENTS.md` Rule 3).

| Field | Source |
|-------|--------|
| `profile` | The profile module (`nil` from `from_manifest/2`) |
| `manifest` | `opts[:manifest]`, else `profile.manifest/0` |
| `mapping_source`, `input_formatter`, `output_formatter` | `manifest.custom.ash_rpc` |
| `resource_lookup`, `type_lookup`, `action_lookup` | `manifest.custom.ash_rpc.lookups` |
| `entrypoints` | `manifest.custom.ash_rpc.entrypoints`, keyed by wire name |

- `new/2` raises `ArgumentError` naming the profile when the manifest has no
  `custom.ash_rpc` decoration (`test/runtime_test.exs` "an undecorated profile
  manifest raises ArgumentError naming the profile").
- `new/2` snapshots profile, formatters and lookups (`test/runtime_test.exs`
  "new/2 snapshots profile, formatters and lookups"); `manifest:` overrides the
  profile's manifest ("manifest: option overrides the profile's manifest").
- `AshRpc.Runtime.from_manifest(manifest, profile \\ nil)` builds one without a
  profile, for callers that only need lookups and formatters
  (`test/runtime_test.exs` "from_manifest/2 works without a profile …").

## `AshRpc.Context`

Actor, tenant and Ash context for one call, independent of transport.

| Field | Default |
|-------|---------|
| `actor` | `nil` |
| `tenant` | `nil` |
| `context` | `%{}` |
| `transport` | `:direct` (`:http` from a conn, `:channel` from a socket) |

- `from_source/1` passes a context through and dispatches conns and sockets.
- `from_conn/1` reads `Ash.PlugHelpers.get_actor/1`, `get_tenant/1` and
  `get_context/1`.
- `from_socket/1` reads `socket.assigns[:ash_actor | :ash_tenant | :ash_context]`
  (context defaults to `%{}`).
- `put_tenant_param/2` overrides the tenant; `nil` keeps it.

`from_conn/1` and `from_socket/1` only exist when plug / phoenix are loaded.
`from_conn/1`, `from_socket/1` and `put_tenant_param/2` are covered in
`test/context_test.exs`; `from_source/1` is exercised through every
`run_action` call.

## The four stages

`lib/ash_rpc/pipeline.ex`. `run_action/4` runs all four; any `{:error, reason}`
short-circuits into `Pipeline.error_response/3`, which builds the error maps
(`AshRpc.ErrorBuilder` for pipeline reasons, `AshRpc.Errors` for Ash errors)
and formats them like a normal response.

### 1. `Pipeline.parse_request(runtime, ctx, params, opts \\ [])`

Returns `{:ok, %AshRpc.Request{}}` or `{:error, reason}`. Fails fast; in order:

1. Pops `"input"` and `"identity"` (passed on untouched) and parses every other
   param key with the input formatter (`getBy` → `:get_by`,
   `metadataFields` → `:metadata_fields`).
2. Applies the `tenant` param with `AshRpc.Context.put_tenant_param/2`.
3. Resolves the entrypoint: the `entrypoint:` option if given, else
   `runtime.entrypoints[params["action"]]`. A missing or empty action is
   `{:missing_required_parameter, :action}`; an unknown name is
   `{:action_not_found, name}`.
4. Reads the action with `AshRpc.Introspection.get_action!(runtime, resource,
   action)`, then `augment_action/2` sets `action.get?` to true when the
   entrypoint has `get?: true` or a non-empty `get_by`.
5. Normalizes `entrypoint.load_restrictions` with
   `AshRpc.LoadRestrictions.normalize/1`.
6. Checks `fields`: required (`missing_required_parameter`,
   `invalid_fields_type`, `empty_fields_array`) for reads and for generic
   actions with a typed return; not required for create/update/destroy,
   generic actions returning an unconstrained map, or in validation mode.
7. Checks top-level `filter` / `sort` / `page` (see
   [below](#filter-sort-and-page)).
8. Processes fields with `AshRpc.RequestedFieldsProcessor.process/5`
   (atomize, select, build the extraction template, enforce load restrictions
   and nested filter/sort flags). Skipped in validation mode when no fields are
   sent. See [field selection](field-selection.md).
9. Formats `input` with `AshRpc.InputFormatter` ([formatting](formatting.md)),
   parses `getBy` and `page`, formats the sort string to internal names, and
   resolves `metadataFields` against `entrypoint.exposed_metadata_fields`.

### 2. `Pipeline.execute_ash_action(request)`

Runs the Ash call with the request's actor, tenant and context and returns the
raw Ash result (`{:ok, result}` or `{:error, error}`).

| Action type | What runs |
|-------------|-----------|
| `:read`, `action.get?` | `Ash.read_one/1` with select/load and the `getBy` filter. A nil result is `Ash.Error.Query.NotFound` unless `entrypoint.not_found_error?` is false |
| `:read` | `Ash.read/1` with select/load, `filter` (`Ash.Query.filter_input/2`), `sort` (`Ash.Query.sort_input/2`) and `page` |
| `:create` | `Ash.Changeset.for_create/4` with select/load, `Ash.create/1` |
| `:update` / `:destroy` | `Ash.bulk_update/4` / `Ash.bulk_destroy/4` over a query narrowed by the identity and limited to 1, with `read_action: entrypoint.read_action` when set. Zero matched records is `not_found` for update and empty data for destroy |
| `:action` | `Ash.run_action/1`; a resource-returning action gets the requested loads applied with `Ash.load/3`; a bare `:ok` becomes `%{}` |

Identity errors (`missing_identity`, `invalid_identity`) come from this stage,
when the bulk target query is built.

### 3. `Pipeline.process_result(ash_result, request)`

Returns `{:ok, data}` or passes `{:error, error}` through.

- Unconstrained-map generic actions: the result is normalized and returned
  without field selection.
- Typed-map generic returns: extracted against `action.returns` with the
  template.
- Everything else (records, lists, offset/keyset pages): `AshRpc.ResultProcessor.process/4`
  with the extraction template.
- Mutations with no fields: `%{}`, plus metadata when requested.
- Action metadata is merged in last ([action metadata](action-metadata.md)).

### 4. `Pipeline.format_output(%{success: true, data: data}, request)`

Formats values with `AshRpc.ValueFormatter` (`:output`) against the resource,
or the generic action's `returns`, and formats the envelope keys (`success`,
`data`, `metadata`) with the output formatter. Page maps keep their page keys
(formatted); only `results` are formatted against the resource. Unconstrained
maps pass through untouched. See [formatting](formatting.md).

## `AshRpc.Request`

`lib/ash_rpc/request.ex`. Built by stage 1, read by stages 2–4.

| Field | Content |
|-------|---------|
| `resource` | The entrypoint's resource |
| `action` | `%Ash.Info.Manifest.Action{}` from the action lookup, after `augment_action/2` |
| `entrypoint` | The resolved `%AshRpc.Entrypoint{}` |
| `tenant`, `actor`, `context` | From the context, after the `tenant` param |
| `select` | Attributes to select |
| `load` | Relationships, calculations and aggregates to load |
| `extraction_template` | Template consumed by `ResultProcessor` |
| `input` | Formatted action input (internal names) |
| `identity` | The raw `identity` param, for update/destroy |
| `get_by` | Parsed `getBy` map (internal names), or `nil` |
| `filter` | Parsed filter (internal names), or `nil` |
| `sort` | Sort string with internal names, or `nil` |
| `pagination` | Parsed page map, or `nil` |
| `runtime` | The `%AshRpc.Runtime{}` |
| `show_metadata` | Metadata fields to return (default `[]`) |

There is no primary-key field: update/destroy use `identity`, get-style reads
use `get_by`.

## `validate_action` and native validation

`AshRpc.validate_action/4` runs stage 1 with `validation_mode?: true` (fields
optional), then `AshRpc.Validation.validate/1`, which builds the query,
changeset or action input without executing it and sends its errors through
`AshRpc.Errors` (no AshPhoenix). Covered in `test/validation_test.exs`:

- A missing required input is type `required`, `fields: ["title"]` ("create: a
  missing required attribute is a native 'required' error"). The message,
  `"attribute title is required"`, comes from Ash and isn't asserted.
- A valid create returns `%{"success" => true}` and persists nothing
  ("create: nothing is persisted").
- Update/destroy load the target with `Ash.get/3` using the entrypoint's
  `read_action` (primary read when unset), so records hidden by it look missing
  ("the read_action used for the lookup is the entrypoint's", "update: unknown
  identity is not_found"). Existing records validate and stay unchanged.
- A bad argument cast on a read, create, update or destroy is
  `invalid_argument` (the changeset/query `InvalidArgument` impl,
  `test/error_protocol_test.exs` "changeset and query InvalidArgument share one
  impl"). Generic actions raise `Ash.Error.Action.InvalidArgument`, which has no
  built-in `AshRpc.Error` impl, so a bad cast there is `internal_error`.
- Atomic validations on update/destroy only run during `run_action`, so
  `validate_action` can succeed where `run_action` fails.

## Transports

Both are optional and wrapped in `Code.ensure_loaded?/1`; they only exist when
plug / phoenix are in the consumer's deps.

- **`AshRpc.Plug.run(conn, profile)` / `validate(conn, profile)`** call the
  entry points with `conn.params` and always respond 200 with a JSON body
  (`test/plug_test.exs` "run/2 responds 200 with the JSON envelope",
  "pipeline exceptions respond 200 with a wire error").
- **`use AshRpc.Channel, profile: MyExt.RpcProfile`** injects
  `handle_in("run" | "validate", …)`, replying `{:ok, result}`, and a catch-all
  replying `{:error, %{reason: "Unknown event: …", payload: …}}`. Because of the
  catch-all, define no further `handle_in/3` clauses. For extra events, skip
  `use AshRpc.Channel` and call `AshRpc.Channel.run/3` / `validate/3` from
  your own `handle_in/3`
  (`test/channel_test.exs`).

```elixir
defmodule MyExt.RpcChannel do
  use Phoenix.Channel
  use AshRpc.Channel, profile: MyExt.RpcProfile

  @impl true
  def join("rpc:" <> _, _payload, socket), do: {:ok, socket}
end
```

## `tenant` param

A `tenant` request param overrides the conn, socket or context tenant and is
passed to Ash unvalidated. Covered in `test/multitenancy_test.exs` with the
attribute-multitenant `AshRpc.Test.Note`:

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{tenant: "w1"}, %{
  "action" => "list_notes",
  "fields" => ["title"],
  "tenant" => "w2"
})
# => %{"success" => true, "data" => [%{"title" => "two"}]}   (only w2's notes)
```

- "overrides the context tenant", "overrides the conn tenant", and
  `AshRpc.MultitenancyChannelTest` "a tenant param overrides the socket tenant".
- Without any tenant, a multitenant read is `tenant_required` ("a read is
  tenant_required") and a create is `invalid_changes` ("a create is
  invalid_changes").
- A non-multitenant resource accepts the param and runs normally ("is accepted
  and the action runs").
- Nested envelopes stay inside the tenant ("a paged replies envelope stays
  inside the tenant").

## `filter`, `sort` and `page`

### Sort

Sort strings are formatted to internal names by
`AshRpc.FieldFormatter.format_sort_string/2` and applied with
`Ash.Query.sort_input/2`. A string or a list (`test/filter_sort_test.exs`
"sort strings", "sort lists"):

| Form | Meaning |
|------|---------|
| `"title"`, `"+title"` | Ascending |
| `"-title"` | Descending |
| `"++slug"` | Ascending, nils first |
| `"--slug"` | Descending, nils last |
| `"viewCount,-title"`, `["-viewCount", "title"]` | In order; client (camelCase) names |

### Filter

Filter keys and operators are parsed with the input formatter and applied with
`Ash.Query.filter_input/2`, e.g. `%{"slug" => %{"isNil" => true}}`, also inside
`and` / `or` ("filter with isNil"; "filter and sort reach the request with
internal names" shows `request.filter == %{slug: %{is_nil: true}}`).

### When `filter` / `sort` / `page` are rejected

`validate_top_level_query_params/3` checks each param that is present. An
empty map or string still counts as present; absent or `nil` never errors.

| Situation | Error | `details.reason` |
|-----------|-------|------------------|
| Non-list action (any non-read action, or a read made single by `get?` / `get_by`) with `filter` or `sort` | `filter_not_supported` / `sort_not_supported` | `:unsupported` |
| List read, `entrypoint.enable_filter?: false` with `filter` | `filter_not_supported` | `:disabled` |
| List read, `entrypoint.enable_sort?: false` with `sort` | `sort_not_supported` | `:disabled` |
| `page` on a non-list action, or on a read without pagination | `pagination_not_supported` | `:unsupported` |

- `details.reason` is an atom in the response map (JSON-encodes to a string).
- Filter is checked before sort, so a request breaking both reports only
  `filter_not_supported` ("filter is checked before sort").
- Disabling one flag leaves the other, and `input`/`page`, unaffected ("sort
  still works", "filter still works", "input and pagination are unaffected").
- Wire rows: `list_posts_no_filter`, `list_posts_no_sort`,
  `list_posts_no_filter_no_sort` in `test/support/manifest_builder.ex`;
  "a filter on a get entrypoint is unsupported, not disabled" uses `get_post`.
- The same flags gate `filter`/`sort` inside nested relationship envelopes
  ([field selection](field-selection.md)).

### Page

Allowed keys are `limit`, `offset`, `count`, `after`, `before`
(`test/nested_query_opts_test.exs` "top-level pagination"):

- `"page" => %{"limit" => 2, "offset" => 0, "count" => true}` on a paginated
  read returns the page shape, keys `count hasMore limit offset results type`
  ("a page on a paginated read returns the offset page shape").
- Bare top-level `limit` / `offset` without `page` are ignored and the result
  is a plain list ("top-level limit/offset without page are ignored and return
  a plain list").
- An unknown page key is `invalid_pagination` with `path: ["page"]` ("an
  unknown page key is invalid_pagination on the page path"); a non-map `page`
  is `invalid_pagination` too.

## Get actions and identities

Covered in `test/get_actions_test.exs`; wire rows in `manifest_builder.ex`.

### Get-style reads

- **`get?: true`** (`get_post`): returns a single map, not a list; no record is
  `not_found` (describe "get? entrypoint").
- **`get_by: [...]`** (`get_post_by_slug`, `get_post_by_slug_and_title`): the
  `getBy` param carries exactly those fields under client names (describe
  "getBy").
  - A missing key is `missing_required_input` ("a missing getBy key is
    missing_required_input").
  - An extra key is `unexpected_get_by_fields` with `details.allowedFields`.
  - An operator map or a list as a value is `invalid_get_by`; lookups are
    equality-only (describe "non-scalar lookup values").
- **`not_found_error?: false`** (`get_post_by_slug_nullable`): no match is
  `%{"success" => true, "data" => nil}` (describe "not_found_error?: false").

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "get_post_by_slug",
  "getBy" => %{"slug" => "wanted"},
  "fields" => ["id", "title"]
})
```

### Identities (update / destroy)

`entrypoint.identities` lists what the `identity` param may be
(describe "identities", "missing_identity", "actor-scoped entrypoints"):

- `:_primary_key` (the default): the primary key as a scalar (`update_author`
  with `"identity" => author.id`). Composite keys are a map.
- A named identity (`update_post_by_slug`, identity `:unique_slug`;
  `update_author_by_identity`, `[:_primary_key, :name_active]`): a map with
  client field names, e.g. `%{"name" => …, "isActive" => true}`. Extra keys
  are ignored.
- A non-matching value is `not_found` and changes nothing.
- `invalid_identity`: a scalar when the primary key isn't allowed, keys that
  match no listed identity (with `details.providedKeys` / `expectedKeys` in
  client names), an empty map, or a non-scalar value.
- `missing_identity`: no `identity` param when `identities` is non-empty;
  `details.expectedKeys` lists every accepted key.
- `identities: []` is actor-scoped: no identity is read, and the target comes
  from `read_action` (`update_me` / `destroy_me` with `read_action: :me`).

## Calling stages directly

For tests or custom handling, the stages compose the same way `run_action/4`
does. Errors are turned into a response with `AshRpc.error_response/3`.

```elixir
alias AshRpc.Pipeline

runtime = AshRpc.Runtime.new(AshRpc.Test.Profile)
params = %{"action" => "list_posts", "fields" => ["id", "title"]}

{:ok, request} = Pipeline.parse_request(runtime, %AshRpc.Context{}, params)
{:ok, ash_result} = Pipeline.execute_ash_action(request)
{:ok, processed} = Pipeline.process_result(ash_result, request)

Pipeline.format_output(%{success: true, data: processed}, request)
# => %{"success" => true, "data" => [%{"id" => …, "title" => "Hello"}]}
```

Parse-only tests use the first line alone and match `{:error, reason}`
(e.g. `parse/1` in `test/filter_sort_test.exs`).
