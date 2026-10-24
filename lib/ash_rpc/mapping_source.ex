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

  `custom_type_fields/1` and `custom_type_fields_hint/1` are optional. An
  extension whose declarations need state passes `decorate/3`'s
  `custom_type_fields:` option instead, which replaces the callback.
  """

  @type formatter ::
          :camel_case
          | :snake_case
          | :pascal_case
          | {module(), atom()}
          | {module(), atom(), list()}

  @callback output_formatter() :: formatter()
  @callback exposed_resource?(resource :: module()) :: boolean()
  @doc "Client-name overrides only; unlisted fields use the output formatter."
  @callback field_names(resource :: module()) :: %{atom() => String.t()}
  @callback argument_names(resource :: module(), action :: atom()) :: %{atom() => String.t()}
  @callback type_field_names(type :: module()) :: %{atom() => String.t()} | nil
  @doc "Return `nil` to keep the entrypoint off the wire."
  @callback entrypoint(Ash.Info.Manifest.Entrypoint.t()) :: AshRpc.Entrypoint.t() | nil

  @typedoc """
  `{field_name, opts}`, in the format of a typed map's `fields` constraint:
  `type:` (required), `constraints:`, `allow_nil?:` (default `true`),
  `description:`, plus `client_name:`, the field's client name (ahead of
  `type_field_names/1` and the output formatter).
  """
  @type field_spec :: {atom(), keyword()}

  @doc """
  Fields for a custom `use Ash.Type` module (a `kind: :unknown` node in the
  manifest), or `nil` when it declares none. Decoration makes a declared
  module a named `kind: :map` type and its uses `:type_ref`s to it.
  """
  @callback custom_type_fields(module()) :: [field_spec()] | nil

  @doc "Extra text for the error about a map-like custom type without fields."
  @callback custom_type_fields_hint(module()) :: String.t() | nil

  @optional_callbacks custom_type_fields: 1, custom_type_fields_hint: 1
end
