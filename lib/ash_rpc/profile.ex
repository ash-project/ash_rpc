# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Profile do
  @moduledoc """
  Runtime configuration for one extension's RPC endpoint.

      defmodule MyApp.RpcProfile do
        use AshRpc.Profile, manifest: MyApp.Manifest
      end

  `manifest:` names a module resolved with `AshRpc.Manifest.fetch!/1`. Omit it
  and define `manifest/0` yourself to compute the manifest differently.
  Defaults: `error_handler/1` → `AshRpc.DefaultErrorHandler`,
  `show_raised_errors?/1` → `false`, `show_policy_breakdowns?/0` → `false`,
  `stale_client_hint/0` → `default_stale_client_hint/0`.
  `error_handler/1` and `show_raised_errors?/1` receive `nil` before an
  entrypoint is resolved.
  """

  @callback manifest() :: Ash.Info.Manifest.t()
  @callback error_handler(domain :: module() | nil) :: {module(), atom(), list()} | module() | nil
  @callback show_raised_errors?(domain :: module() | nil) :: boolean()
  @callback show_policy_breakdowns?() :: boolean()

  @doc """
  `details.hint` on request errors that a client generated from an older
  manifest could cause (unknown fields or actions, missing inputs, disabled
  filter/sort, denied loads, …). Return `nil` to omit the hint.
  """
  @callback stale_client_hint() :: String.t() | nil

  @doc "The client-neutral default for `c:stale_client_hint/0`."
  @spec default_stale_client_hint() :: String.t()
  def default_stale_client_hint do
    "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes."
  end

  defmacro __using__(opts) do
    manifest_module = Keyword.get(opts, :manifest)

    quote do
      @behaviour AshRpc.Profile

      if unquote(manifest_module) do
        @impl AshRpc.Profile
        def manifest, do: AshRpc.Manifest.fetch!(unquote(manifest_module))
        defoverridable manifest: 0
      end

      @impl AshRpc.Profile
      def error_handler(_domain), do: AshRpc.DefaultErrorHandler

      @impl AshRpc.Profile
      def show_raised_errors?(_domain), do: false

      @impl AshRpc.Profile
      def show_policy_breakdowns?, do: false

      @impl AshRpc.Profile
      def stale_client_hint, do: AshRpc.Profile.default_stale_client_hint()

      defoverridable error_handler: 1,
                     show_raised_errors?: 1,
                     show_policy_breakdowns?: 0,
                     stale_client_hint: 0
    end
  end
end
