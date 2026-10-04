# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.MappingSource do
  @moduledoc """
  Compile-time source of client-facing names for one extension.

  `AshRpc.Manifest.Decorator.decorate/3` calls these callbacks while the
  extension builds its manifest and precomputes the results under
  `custom.ash_rpc`. The runtime never calls them, with one exception:
  `type_field_names/1` is the fallback for type modules that aren't in the
  manifest's type lookup (see `AshRpc.Introspection.type_field_name_overrides/2`).
  """

  @type formatter ::
          :camel_case
          | :snake_case
          | :pascal_case
          | {module(), atom()}
          | {module(), atom(), list()}

  @callback input_formatter() :: formatter()
  @callback output_formatter() :: formatter()
  @callback exposed_resource?(resource :: module()) :: boolean()
  @doc "Client-name overrides only; unlisted fields use the output formatter."
  @callback field_names(resource :: module()) :: %{atom() => String.t()}
  @callback argument_names(resource :: module(), action :: atom()) :: %{atom() => String.t()}
  @callback type_field_names(type :: module()) :: %{atom() => String.t()} | nil
  @doc "Return `nil` to keep the entrypoint off the wire."
  @callback entrypoint(Ash.Info.Manifest.Entrypoint.t()) :: AshRpc.Entrypoint.t() | nil
end
