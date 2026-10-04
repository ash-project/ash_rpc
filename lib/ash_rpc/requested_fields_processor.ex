# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.RequestedFieldsProcessor do
  @moduledoc """
  Processes requested fields for Ash resources, determining which fields should be selected
  vs loaded, and building extraction templates for result processing.

  This module handles different action types:
  - CRUD actions (:read, :create, :update, :destroy) return resource records
  - Generic actions (:action) return arbitrary types as specified in their `returns` field

  ## Architecture

  Delegates to `FieldSelector`, which uses a unified type-driven recursive
  dispatch pattern (similar to `ValueFormatter`). Each type is self-describing
  via `{type, constraints}`, so no separate classification step is needed.

  ## Runtime

  Field selection reads its lookups (`resources`, `actions`, `types`) and the
  input formatter from an `AshRpc.Runtime`, passed explicitly by every caller.
  """

  alias AshRpc.FieldProcessing.{Atomizer, FieldSelector}

  @doc """
  Applies `resource`'s field-name overrides to the top level of a field selection.
  See `AshRpc.FieldProcessing.Atomizer`.
  """
  defdelegate atomize_requested_fields(requested_fields, resource, runtime), to: Atomizer

  @doc """
  Processes requested fields for a given resource and action.

  Returns `{:ok, {select_fields, load_fields, extraction_template}}` or `{:error, error}`.
  """
  def process(runtime, resource, action_name, requested_fields, opts \\ []) do
    FieldSelector.process(runtime, resource, action_name, requested_fields, opts)
  end
end
