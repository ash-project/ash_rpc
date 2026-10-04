<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Errors

Every failure leaves ash_rpc as `%{"success" => false, "errors" => [error, …]}`.
There are two sources of error maps:

- **Pipeline reasons** (tuples such as `{:action_not_found, name}` or
  `{:load_not_allowed, paths}`) returned or thrown by the pipeline stages.
  `AshRpc.ErrorBuilder` turns these into error maps.
- **Ash errors and other exceptions** from running the action, from native
  validation (`AshRpc.Validation`) or raised inside the request. These go
  through `AshRpc.Errors.to_errors/6`: the `AshRpc.Error` protocol, then the
  handlers.

Both paths end in `AshRpc.ErrorFormatter`, which applies the output
formatter's casing. Exceptions raised anywhere inside `AshRpc.run_action/4` or
`validate_action/4` are rescued and returned as failure responses too (see
[pipeline](pipeline.md)).

## Wire error shape

| Key | Content |
|-----|---------|
| `type` | Machine-readable type, e.g. `"load_not_allowed"`, `"required"`, `"not_found"` |
| `message` | Full message. A template: `%{name}` placeholders are left in and filled from `vars` by the client |
| `shortMessage` | Short title |
| `vars` | Placeholder values |
| `fields` | Affected client field names (dotted for nested paths) |
| `path` | Client-formatted path to the error location |
| `details` | Optional extras: `suggestion`, `hint` (see [stale-client hint](#stale-client-hint)) and reason-specific keys |
| `errorId` | Only on `internal_error`: the id that is also logged server-side |

Interpolation is left to the client on purpose so messages can be localized.
Example, `test/load_restrictions_test.exs` "load_not_allowed carries the
disallowed paths" (entrypoint `list_posts_allow_author`, which allows only
`author`):

```elixir
AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, %{
  "action" => "list_posts_allow_author",
  "fields" => ["id", %{"comments" => ["id"]}]
})
#=> %{"success" => false, "errors" => [%{
#     "type" => "load_not_allowed",
#     "message" => "Loading the following fields is not allowed: %{fields}",
#     "shortMessage" => "Load not allowed",
#     "fields" => ["comments"],
#     "path" => [],
#     "vars" => %{"fields" => "comments"},
#     "details" => %{"disallowedPaths" => ["comments"], "suggestion" => …, "hint" => …}
#   }]}
```

## The `AshRpc.Error` protocol

`AshRpc.Error.to_error/1` turns one exception into a map with `message`,
`short_message`, `type`, `vars`, `fields`, `path` and optionally `details`.
Built-in impls live in `lib/ash_rpc/error.ex`:

| Exception | `type` |
|-----------|--------|
| `Ash.Error.Changes.InvalidChanges` | `invalid_changes` |
| `Ash.Error.Query.InvalidQuery` | `invalid_query` |
| `Ash.Error.Query.NotFound` | `not_found` |
| `Ash.Error.Changes.Required`, `Ash.Error.Query.Required` | `required` |
| `Ash.Error.Forbidden.Policy` | `forbidden` |
| `Ash.Error.Forbidden.ForbiddenField` | `forbidden_field` |
| `Ash.Error.Changes.InvalidAttribute` | `invalid_attribute` |
| `Ash.Error.Changes.InvalidArgument`, `Ash.Error.Query.InvalidArgument` | `invalid_argument` |
| `Ash.Error.Page.InvalidKeyset` | `invalid_keyset` |
| `Ash.Error.Query.InvalidPage` | `invalid_page` |
| `Ash.Error.Invalid.TenantRequired` | `tenant_required` |
| `Ash.Error.Invalid.InvalidPrimaryKey` | `invalid_primary_key` |
| `Ash.Error.Query.ReadActionRequiresActor` | `forbidden` |
| `Ash.Error.Unknown.UnknownError` | `unknown_error` |

Behaviour worth knowing (`test/error_protocol_test.exs` unless noted):

- Changeset and query variants share one impl ("changeset and query Required
  share one impl", "changeset and query InvalidArgument share one impl").
- An impl that raises falls back to a generic `type: "error"`, `"something went
  wrong"` map that keeps the exception's path ("a raising AshRpc.Error impl"
  describe).
- A Splode/Ash-class exception with no impl becomes `internal_error` with a
  fresh `errorId`; the full exception is only logged (`test/errors_test.exs`
  "show_raised_errors? exposes the exception message for that domain only"). A
  plain exception (e.g. `RuntimeError`) is first wrapped by
  `Ash.Error.to_error_class/1` and becomes `unknown_error`.
- `Ash.Error.to_error_class/1` wraps non-exception terms, so a non-exception
  struct becomes `unknown_error` and never reaches an impl ("non-exception
  structs are wrapped as unknown errors and never reach an impl").
- The `Forbidden.Policy` impl always says `"forbidden"`; it never leaks a
  breakdown (`test/errors_test.exs` "the protocol impl itself never leaks a
  breakdown").
- An extension or app adds its own impls with `defimpl AshRpc.Error, for: …`
  (`test/errors_test.exs` "custom AshRpc.Error impls are used").

## `AshRpc.Errors.to_errors/6`

`to_errors(runtime, errors, domain \\ nil, resource \\ nil, action \\ nil, context \\ %{})`
returns a list of error maps. For pipeline execution errors and validation
errors, `domain` is `entrypoint.domain`, `resource` and `action` come from the
request and `context` is the request's Ash context. Errors from
`parse_request`, and exceptions rescued at the top level of `run_action` /
`validate_action` or passed to `error_response/3`, get `nil` for all of them
(and `%{}` context), so the profile sees `error_handler(nil)` /
`show_raised_errors?(nil)`. The order is:

1. `Ash.Error.to_error_class/1`.
2. Unwrap nested `errors` lists into single errors.
3. Per error: the protocol, or, when the profile's `show_raised_errors?(domain)`
   is true and the error is an exception, the raw exception message (`type` is
   the underscored exception name).
4. If the source is `Ash.Error.Forbidden.Policy` and the profile's
   `show_policy_breakdowns?/0` is true, `message` becomes the policy breakdown.
5. The resource handler: `handle_rpc_error(error, context)` on the resource
   module, if exported.
6. The profile handler: `error_handler(domain)` returns a module (its
   `handle_error/2` is called), an `{m, f, a}` tuple (called as
   `apply(m, f, [error, context | a])`), or `nil` (skipped). The default is
   `AshRpc.DefaultErrorHandler`, which returns the error unchanged.
7. `fields` and `vars.field` are formatted for the client using the resource's
   field-name overrides when the resource is known; `path` segments get plain
   formatter casing only. Values are
   made JSON-safe (unknown structs are reduced to their module name so their
   fields are not disclosed).

A handler returning `nil` drops the error and the remaining handlers are
skipped. A handler that raises or throws fails closed: the error becomes a
generic `internal_error` ("Something went wrong. Unique error id: …") with an
`errorId`, never the unredacted original; the failure is logged.

Asserted in `test/errors_test.exs`:

- "a handler returning nil drops the error"
- "an error dropped by the resource handler skips the profile handler"
- "show_raised_errors? exposes the exception message for that domain only"
- "policy errors are 'forbidden' unless the profile shows breakdowns" (the
  profile handler sees the breakdown message, so breakdowns are applied before
  handlers)
- "the protocol impl itself never leaks a breakdown"

## `AshRpc.ErrorHandler`

```elixir
@callback handle_error(error :: map(), context :: map()) :: map() | nil
```

`error` is the atom-keyed map from the protocol (before client formatting).
`context` is the request's Ash context map (`%AshRpc.Context{}.context`, from
`Ash.PlugHelpers` on a conn or the `ash_context` socket assign), or `%{}` for
errors without a scope (see above). Handlers only see Ash errors and
exceptions: pipeline reasons built by `ErrorBuilder` (`action_not_found`,
`load_denied`, …) never pass through them. The handler chooses per domain
through the profile:

```elixir
defmodule MyExt.ErrorHandler do
  @behaviour AshRpc.ErrorHandler

  @impl true
  def handle_error(%{type: "internal_error"}, _context), do: nil
  def handle_error(error, _context), do: Map.put(error, :message, "Request failed")
end

defmodule MyExt.RpcProfile do
  use AshRpc.Profile, manifest: MyExt.Manifest

  @impl AshRpc.Profile
  def error_handler(_domain), do: MyExt.ErrorHandler
end
```

## Pipeline reasons: `AshRpc.ErrorBuilder`

`AshRpc.ErrorBuilder.build_error_response(runtime, reason, scope \\ nil)`
returns one error map or a list. `scope` is `nil` or
`%{domain:, resource:, action:, context:}`. Each `build/2` clause handles one
reason shape. Lists (e.g. bulk results) are built element by element, and any
exception or Ash error is passed to `AshRpc.Errors.to_errors/6` with the
scope, so domain handlers apply to execution errors too.

`test/support/error_cases.ex` holds one representative reason per clause,
keyed by a label. `test/error_builder_golden_test.exs` snapshots the wire output
of `AshRpc.error_response(AshRpc.Test.Profile, reason)` for each case in its
`@golden` map, and "the snapshot covers every case" fails when a case has no
snapshot entry. Any diff there is a wire change for clients:

- Update a snapshot entry only for an intentional wire change.
- When adding a `build/2` clause, add a case to `error_cases.ex` and its
  expected output to `@golden`.

## Stale-client hint

Some request errors happen when a client was built against an older manifest
than the running backend has: unknown fields or actions, missing inputs,
disabled filter/sort, denied loads, and so on. `ErrorBuilder` puts the
profile's `stale_client_hint/0` into `details.hint` on those. The default is
`AshRpc.Profile.default_stale_client_hint/0`. The hint is omitted when the
callback returns `nil`, and on malformed requests a conforming client never
sends (`invalid_input_format`, `invalid_pagination`, `invalid_fields_type`, …).
See `test/errors_test.exs` "stale client hint" describe. The union-input
multiple-member-keys error carries no hint either
(`test/error_builder_golden_test.exs` "invalid_union_input_multiple_member_keys").

## `AshRpc.ErrorFormatter`

`AshRpc.ErrorFormatter.format(error, formatter)` formats every key of an error
map with the output formatter. Because `message`, `shortMessage` and the
strings in `details` are templates, it also rewrites `%{name}` placeholders to
match the renamed `vars`/`details` keys, so `"%{action_name}"` becomes
`"%{actionName}"` under `:camel_case`. Values inside `vars` are data and stay
untouched. The pipeline applies it to every error in a failure response.

## Building responses by hand

- `AshRpc.error_response(profile, reason, opts \\ [])`: a client-formatted
  failure response for a pipeline reason or an exception (runs `ErrorBuilder`
  with no scope).
- `AshRpc.failure_response(profile, errors, opts \\ [])`: a client-formatted
  failure response for error maps you already built.

Both accept the `manifest:` option, like `run_action/4`. See
[decoration](decoration.md) for varying the formatter.
