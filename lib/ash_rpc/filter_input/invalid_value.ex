# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterInput.InvalidValue do
  @moduledoc """
  A filter operator value that `AshRpc.ValueFormatter.format_input/3`
  rejected: an unknown key (`{:unknown_input, key, path}`, `path` relative to
  the value) or a malformed union (`{:invalid_union_input, …}`).

  `path` locates the value in the request: `:filter`, then the keys as the
  client sent them (fields, relationships, `and`/`or`/`not`, list indexes) down
  to the operator. `AshRpc.Errors` renders `reason` with `AshRpc.ErrorBuilder`
  under that path, so the client gets the same `unknown_input` /
  `invalid_union_input` error an action input would produce.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{
          reason: AshRpc.ValueFormatter.input_error(),
          path: [atom() | String.t() | non_neg_integer()]
        }

  @impl true
  def message(%{reason: reason, path: path}),
    do: "Invalid filter value at #{inspect(path)}: #{inspect(reason)}"
end
