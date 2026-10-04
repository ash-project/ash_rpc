<!--
SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# AshRpc

Client-agnostic RPC runtime for [Ash](https://hexdocs.pm/ash).

An extension decorates an `Ash.Info.Manifest` with `AshRpc.Manifest.Decorator`
(driven by an `AshRpc.MappingSource`), defines an `AshRpc.Profile`, and mounts
an endpoint that calls `AshRpc.run_action/4` / `AshRpc.validate_action/4`, or
uses `AshRpc.Plug` / `AshRpc.Channel`.

`plug` and `phoenix` are optional; `AshRpc.Plug` and `AshRpc.Channel` only
compile when they are available.
