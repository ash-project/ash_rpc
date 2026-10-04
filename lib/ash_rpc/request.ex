# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Request do
  @moduledoc """
  Request data structure for the RPC pipeline.

  Contains all parsed and validated request data needed for Ash execution.
  Immutable structure that flows through the pipeline stages.
  """

  @type t :: %__MODULE__{
          resource: module(),
          action: map(),
          tenant: term(),
          actor: term(),
          context: map(),
          select: list(atom()),
          load: list(),
          extraction_template: map(),
          input: map(),
          identity: term(),
          get_by: map() | nil,
          filter: map() | nil,
          sort: list() | nil,
          pagination: map() | nil,
          show_metadata: list(atom()),
          runtime: AshRpc.Runtime.t(),
          entrypoint: AshRpc.Entrypoint.t()
        }

  defstruct [
    :resource,
    :action,
    :entrypoint,
    :tenant,
    :actor,
    :context,
    :select,
    :load,
    :extraction_template,
    :input,
    :identity,
    :get_by,
    :filter,
    :sort,
    :pagination,
    :runtime,
    show_metadata: []
  ]
end
