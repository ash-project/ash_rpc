# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Validation do
  @moduledoc """
  `validate_action` without executing anything: builds the action's query,
  changeset or action input natively and reports its errors through
  `AshRpc.Errors`, so error types match `run_action` (`required`,
  `invalid_attribute`, `invalid_argument`, …).

  Update/destroy targets are read from the query `run_action` narrows
  (`AshRpc.Pipeline.target_query/2`: identity keys by client name, the
  entrypoint's `identities`, scalar values) with the entrypoint's
  `read_action` (primary read when unset), so records hidden by it look
  missing and identity errors match `run_action`'s.

  Known limitations, where `validate_action` can succeed and `run_action`
  fail:

    * Atomic validations on update/destroy only run during execution.
    * Filter, sort and nested query-option errors are not applied: the ones
      `AshRpc.FilterInput` collects (on `Request.query_errors`, or a
      relationship's load query) are only added to what `run_action`
      executes, and Ash's own filter, load and page checks only run then.
      Errors stage 1 returns directly (field selection, envelope shapes,
      `getBy`, `identity`, `input` keys) are reported by both.
  """

  alias AshRpc.{ErrorBuilder, Errors, Pipeline, Request}

  @spec validate(Request.t()) :: %{success: true} | %{success: false, errors: [map()]}
  def validate(%Request{} = request) do
    opts = [
      actor: request.actor,
      tenant: request.tenant,
      context: request.context,
      domain: request.entrypoint.domain
    ]

    case build(request, opts) do
      {:ok, %{valid?: true}} -> %{success: true}
      {:ok, %{errors: errors}} -> failure(request, errors)
      {:error, {:pipeline, reason}} -> pipeline_failure(request, reason)
      {:error, error} -> failure(request, error)
    end
  rescue
    e -> failure(request, e)
  end

  defp build(%Request{action: %{type: :read}} = r, opts),
    do: {:ok, Ash.Query.for_read(r.resource, r.action.name, r.input, opts)}

  defp build(%Request{action: %{type: :create}} = r, opts),
    do: {:ok, Ash.Changeset.for_create(r.resource, r.action.name, r.input, opts)}

  defp build(%Request{action: %{type: :update}} = r, opts) do
    with {:ok, record} <- fetch_target(r, opts),
         do: {:ok, Ash.Changeset.for_update(record, r.action.name, r.input, opts)}
  end

  defp build(%Request{action: %{type: :destroy}} = r, opts) do
    with {:ok, record} <- fetch_target(r, opts),
         do: {:ok, Ash.Changeset.for_destroy(record, r.action.name, r.input, opts)}
  end

  defp build(%Request{action: %{type: :action}} = r, opts),
    do: {:ok, Ash.ActionInput.for_action(r.resource, r.action.name, r.input, opts)}

  defp fetch_target(%Request{} = r, opts) do
    with {:ok, query} <- target_query(r, opts),
         {:ok, %_{} = record} <- Ash.read_one(query, read_opts(r, opts)) do
      {:ok, record}
    else
      {:ok, nil} -> {:error, Ash.Error.Query.NotFound.exception(resource: r.resource)}
      {:error, _} = error -> error
    end
  end

  defp target_query(r, opts) do
    case Pipeline.target_query(r, opts) do
      {:ok, query} -> {:ok, query}
      {:error, reason} -> {:error, {:pipeline, reason}}
    end
  end

  defp read_opts(%Request{entrypoint: %{read_action: nil}}, opts), do: opts

  defp read_opts(%Request{entrypoint: %{read_action: read_action}}, opts),
    do: Keyword.put(opts, :action, read_action)

  defp pipeline_failure(%Request{} = r, reason) do
    errors =
      r.runtime
      |> ErrorBuilder.build_error_response(reason, Pipeline.error_scope(r))
      |> List.wrap()

    %{success: false, errors: errors}
  end

  defp failure(%Request{} = r, errors) do
    %{
      success: false,
      errors:
        Errors.to_errors(
          r.runtime,
          errors,
          r.entrypoint.domain,
          r.resource,
          r.action.name,
          r.context
        )
    }
  end
end
