# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterInput.InvalidValue do
  @moduledoc """
  A filter operator value that `AshRpc.ValueFormatter.format_input/3`
  rejected: an unknown key (`{:unknown_input, key, path}`, `path` relative to
  the value) or a malformed union (`{:invalid_union_input, …}`). Also a
  calculation `input` argument name that is not a client name
  (`{:unknown_input, name, []}` at the `input` key), a calculation `input`
  that is not a map (`:invalid_calculation_input`), and a filter statement
  that is not a map or a list, or an empty `and`/`or`
  (`:invalid_filter_statement`, at the statement), an operator value of the
  wrong shape (`{:invalid_filter_value, expected}`), and a calculation
  argument that is missing or that its type rejects
  (`{:invalid_calculation_argument, client_name, :required | :invalid}`, at
  the calculation's `input`).

  `path` locates the value in the request: `:filter`, then the keys as the
  client sent them (fields, relationships, `and`/`or`/`not`, list indexes) down
  to the operator (the field, for a bare `eq` value; `input` and the
  argument, for a calculation argument value). `AshRpc.Errors` renders
  `reason` with `AshRpc.ErrorBuilder` under that path, so the client gets the
  same `unknown_input` / `invalid_union_input` error an action input would
  produce.
  """

  use Splode.Error, fields: [:reason], class: :invalid

  @type t :: %__MODULE__{
          reason:
            AshRpc.ValueFormatter.input_error()
            | :invalid_calculation_input
            | :invalid_filter_statement
            | {:invalid_filter_value, String.t()}
            | {:invalid_calculation_argument, String.t(), :required | :invalid},
          path: [atom() | String.t() | non_neg_integer()]
        }

  @impl true
  def message(%{reason: reason, path: path}),
    do: "Invalid filter value at #{inspect(path)}: #{inspect(reason)}"
end
