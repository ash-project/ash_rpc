# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Entrypoint do
  @moduledoc """
  The neutral, per-action contract an extension exposes through ash_rpc.

  Built at decoration time by `c:AshRpc.MappingSource.entrypoint/1` and stored
  under `manifest.custom.ash_rpc.entrypoints`, keyed by `name` (the wire
  action name). Entrypoints resolved outside the wire (for example an
  extension's server-side preset queries) set `preset_fields` and are passed to
  `AshRpc.run_action/4` with the `entrypoint:` option.
  """

  @type load_tree :: [atom() | {atom(), load_tree()}]

  @type t :: %__MODULE__{
          name: String.t(),
          domain: module() | nil,
          resource: module(),
          action: atom(),
          read_action: atom() | nil,
          get?: boolean(),
          get_by: [atom()],
          identities: [atom()],
          not_found_error?: boolean(),
          enable_filter?: boolean(),
          enable_sort?: boolean(),
          load_restrictions: :none | {:allow, load_tree()} | {:deny, load_tree()},
          exposed_metadata_fields: [atom()],
          metadata_field_names: %{atom() => String.t()},
          preset_fields: list() | nil
        }

  defstruct [
    :name,
    :domain,
    :resource,
    :action,
    :read_action,
    get?: false,
    get_by: [],
    identities: [:_primary_key],
    not_found_error?: true,
    enable_filter?: true,
    enable_sort?: true,
    load_restrictions: :none,
    exposed_metadata_fields: [],
    metadata_field_names: %{},
    preset_fields: nil
  ]
end
