# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldProcessing.Atomizer do
  @moduledoc """
  Applies a resource's field-name overrides to the top level of a field selection.

  Only top-level names and the keys of top-level maps name fields on
  `resource`; nested selections belong to each field's destination type and
  are left as sent. `AshRpc.FieldProcessing.FieldSelector` applies
  `atomize_field/3` at every resource level as it recurses, so the runtime
  pipeline does not call `atomize_requested_fields/3`; it remains for callers
  that pre-process selections (e.g. an extension validating stored queries).
  """

  alias AshRpc.Manifest.Custom

  @doc """
  Applies `resource`'s field-name overrides to the top level of `requested_fields`.

  ## Examples

      # With an override `is_active?: "isActive"` on MyApp.User:
      atomize_requested_fields(["id", "isActive", %{"posts" => ["title"]}], MyApp.User, runtime)
      #=> ["id", :is_active?, %{"posts" => ["title"]}]
  """
  def atomize_requested_fields(requested_fields, resource, runtime)
      when is_list(requested_fields) do
    Enum.map(requested_fields, &atomize_field(&1, resource, runtime))
  end

  @doc """
  Applies `resource`'s field-name overrides to one selection entry: a field
  name, or the keys of a map. Other entries are returned unchanged.
  """
  def atomize_field(field_name, resource, runtime) when is_binary(field_name),
    do: original_name(field_name, resource, runtime)

  def atomize_field(%{} = field_map, resource, runtime),
    do: Map.new(field_map, fn {key, value} -> {atomize_field(key, resource, runtime), value} end)

  def atomize_field(other, _resource, _runtime), do: other

  defp original_name(name, resource, runtime) do
    res_struct = Map.get(runtime.resource_lookup, resource)

    with true <- Custom.exposed?(res_struct),
         original when is_atom(original) and not is_nil(original) <-
           Custom.original_field_name(res_struct, name) do
      original
    else
      _ -> name
    end
  end
end
