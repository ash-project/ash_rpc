# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Validation do
  @moduledoc """
  `validate_action` without executing anything: builds the action's query,
  changeset or action input natively and reports its errors through
  `AshRpc.Errors`, so error types match `run_action` (`required`,
  `invalid_attribute`, `invalid_argument`, …).

  Update/destroy targets are loaded with the entrypoint's `read_action`
  (primary read when unset), so records hidden by it look missing.

  Known limitation: atomic validations on update/destroy only run during
  execution, so `validate_action` can succeed where `run_action` fails.
  """

  alias AshRpc.{Errors, Request}

  @spec validate(Request.t()) :: %{success: true} | %{success: false, errors: [map()]}
  def validate(%Request{} = request) do
    opts = [actor: request.actor, tenant: request.tenant, context: request.context]

    case build(request, opts) do
      {:ok, %{valid?: true}} -> %{success: true}
      {:ok, %{errors: errors}} -> failure(request, errors)
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

  defp fetch_target(%Request{entrypoint: %{read_action: nil}} = r, opts),
    do: Ash.get(r.resource, r.identity, opts)

  defp fetch_target(%Request{entrypoint: %{read_action: read_action}} = r, opts),
    do: Ash.get(r.resource, r.identity, Keyword.put(opts, :action, read_action))

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
