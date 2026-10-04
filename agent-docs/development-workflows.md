<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# Development Workflows

How to make the common kinds of change in ash_rpc. Test patterns and the full
fixtures table are in [testing.md](testing.md).

## Changing the Pipeline

1. **Write the failing wire test first.** Drive it through
   `AshRpc.run_action(AshRpc.Test.Profile, %AshRpc.Context{}, params)` so it
   asserts what the client sees. Use `AshRpc.Pipeline.parse_request/4` directly
   only when the behaviour ends in `parse_request` (see `parse/1` in
   `test/load_restrictions_test.exs`). Confirm it fails for the right reason.
2. **Find the stage that owns the change.** Request parsing, entrypoint
   resolution, filter/sort/page gating and field selection belong to
   `parse_request`; running Ash belongs to `execute_ash_action`; extraction
   belongs to `process_result`; casing and value formatting belong to
   `format_output`. See [pipeline](features/pipeline.md). Change one stage at a
   time and keep the suite green between steps.
3. **Read shape from the runtime.** Action, resource and type shape comes from
   `request.runtime` lookups via `AshRpc.Introspection.get_action!/3`, never
   from `Ash.Resource.Info` or app env (`AGENTS.md` Rule 3).
4. **Run `mix check`**, not just `mix test`. It also runs format, credo,
   dialyzer, sobelow and `reuse lint`.

A new wire error needs an `ErrorBuilder` clause too; see
[Adding an Error Reason](#adding-an-error-reason).

## Adding a Wire Action

Wire actions for tests are rows in `@entrypoints` in
`test/support/manifest_builder.ex`:

```elixir
{"list_posts_no_sort", AshRpc.Test.Post, :read, enable_sort?: false}
```

- The row is `{wire_name, resource, action}` or
  `{wire_name, resource, action, opts}`. `ManifestBuilder.build/1` puts the
  name and opts into the Ash entrypoint's `config`.
- `AshRpc.Test.MappingSource.entrypoint/1` (`test/support/mapping_source.ex`)
  turns each row into `%AshRpc.Entrypoint{}` with `struct!/2`, so opts are
  `AshRpc.Entrypoint` fields (`get?`, `get_by`, `load_restrictions`,
  `exposed_metadata_fields`, …). A misspelled opt raises `KeyError` and fails
  the manifest build (`test/fixtures_test.exs` "an unknown entrypoint opt
  fails the manifest build").
- The resource must be listed in `@exposed` in
  `test/support/mapping_source.ex` and in `test/support/domain.ex`.
- `ManifestBuilder.manifest/0` is cached in `:persistent_term`; a new row shows
  up on the next test run. Field meanings are in
  [decoration](features/decoration.md).

## Adding a Fixture Resource

1. Create `test/support/<name>.ex` with the SPDX header (copy it from an
   existing fixture) and `@moduledoc false`.
2. Use `data_layer: Ash.DataLayer.Ets` with `ets do private? true end`, as
   every persisted fixture does. Embedded fixtures (`post_settings.ex`,
   `comment_attachment.ex`) use `data_layer: :embedded` instead and are not in
   the domain.
3. Mark the attributes, relationships, calculations and actions the client
   should see as `public?: true`.
4. Add a non-embedded resource to `resources` in `test/support/domain.ex`.
5. Add it to `@exposed` in `test/support/mapping_source.ex` (embedded
   resources too), unless the point is to test exposure. `AshRpc.Test.Secret`
   stays out on purpose: a relationship to it must be `unknown_field`.
6. Add any wire actions to `@entrypoints` (see above).
7. Add a smoke case to `test/fixtures_test.exs` showing the fixture persists
   and loads on ETS (as in "new fixture resources persist, aggregate and
   calculate on ETS").

Then add a row to the fixtures table in [testing.md](testing.md).

## Adding an Error Reason

1. Add a `build/2` clause in `lib/ash_rpc/error_builder.ex`. Use `drift/5` if
   a client built from an older manifest could cause the error (it attaches
   `details.hint` from the profile's `stale_client_hint/0`); use `malformed/4`
   for request shapes a conforming client never sends.
2. Add a case `{"label", reason}` to `cases/0` in
   `test/support/error_cases.ex`.
3. Add the expected wire output under the same label in `@golden` in
   `test/error_builder_golden_test.exs`. The snapshot is a hand-maintained
   map: "the snapshot covers every case" fails until the label exists, and
   "wire output for <label> is unchanged" compares
   `AshRpc.error_response(AshRpc.Test.Profile, reason)` with it.

Edit an existing `@golden` entry only for an intentional wire change; any
diff there is a change every client sees. See [errors](features/errors.md).

## Debugging

Reproduce the problem as a test rather than in a shell: see
[troubleshooting](troubleshooting.md) "Reproduce it in a test". Use `dbg/1`
inside the test, and keep it as a regression test (without the `dbg/1`) once
the fix lands.

## Consumer Compatibility

ash_rpc has consumers that call its public functions and, in some tests, its
internals (`AGENTS.md` Rule 1). Before changing or removing a public `AshRpc*`
function, option or wire shape:

1. Grep the consumers you have checked out locally for the function or
   module name.
2. Run their test suites against your change.
3. Report the consumer changes needed. Don't edit a consumer unless asked,
   and leave any such edits uncommitted.
4. Treat it as a breaking change.
