# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.Custom do
  @moduledoc """
  Accessors for the `custom.ash_rpc` decoration written by
  `AshRpc.Manifest.Decorator`. Every accessor returns `nil` or an empty
  default for undecorated structs.
  """

  alias Ash.Info.Manifest

  @spec ash_rpc(struct() | nil) :: map() | nil
  def ash_rpc(%{custom: %{ash_rpc: data}}), do: data
  def ash_rpc(_), do: nil

  @doc "A resource is exposed exactly when it carries `custom.ash_rpc`."
  @spec exposed?(Manifest.Resource.t() | nil) :: boolean()
  def exposed?(%Manifest.Resource{custom: %{ash_rpc: _}}), do: true
  def exposed?(_), do: false

  # Resources
  def field_names(%Manifest.Resource{custom: %{ash_rpc: %{field_names: m}}}), do: m
  def field_names(_), do: %{}

  def field_name_overrides(%Manifest.Resource{custom: %{ash_rpc: %{field_name_overrides: m}}}),
    do: m

  def field_name_overrides(_), do: %{}

  def field_name_override(resource, field) when is_atom(field),
    do: Map.get(field_name_overrides(resource), field)

  def original_field_name(
        %Manifest.Resource{custom: %{ash_rpc: %{reverse_field_name_overrides: m}}},
        client_name
      ),
      do: Map.get(m, to_string(client_name))

  def original_field_name(_, _), do: nil

  def argument_name_overrides(
        %Manifest.Resource{custom: %{ash_rpc: %{argument_name_overrides: m}}},
        action
      ),
      do: Map.get(m, action, %{})

  def argument_name_overrides(_, _), do: %{}

  def argument_name_override(resource, action, argument),
    do: Map.get(argument_name_overrides(resource, action), argument)

  def original_argument_name(
        %Manifest.Resource{custom: %{ash_rpc: %{reverse_argument_name_overrides: m}}},
        action,
        client_name
      ),
      do: m |> Map.get(action, %{}) |> Map.get(to_string(client_name))

  def original_argument_name(_, _, _), do: nil

  def authorize_bulk_strategy(%Manifest.Resource{
        custom: %{ash_rpc: %{authorize_bulk_strategy: s}}
      }),
      do: s

  def authorize_bulk_strategy(_), do: nil

  # Relationships
  def relationship_pagination(%Manifest.Relationship{custom: %{ash_rpc: %{pagination: p}}}), do: p
  def relationship_pagination(_), do: :none

  def relationship_read_action(%Manifest.Relationship{custom: %{ash_rpc: %{read_action: a}}}),
    do: a

  def relationship_read_action(_), do: nil

  # Types
  def type_field_name_overrides(%Manifest.Type{custom: %{ash_rpc: %{field_name_overrides: m}}}),
    do: m

  def type_field_name_overrides(_), do: %{}

  @doc "`{forward, reverse}` for a decorated type, `nil` when undecorated."
  def type_field_name_overrides_pair(%Manifest.Type{
        custom: %{ash_rpc: %{field_name_overrides: fwd, reverse_field_name_overrides: rev}}
      }),
      do: {fwd, rev}

  def type_field_name_overrides_pair(_), do: nil

  # Actions (entrypoint actions, present in action_lookup)
  def action_return_classification(%Manifest.Action{
        custom: %{ash_rpc: %{return_classification: c}}
      }),
      do: c

  def action_return_classification(_), do: nil

  def action_expected_input_keys(%Manifest.Action{custom: %{ash_rpc: %{expected_input_keys: m}}}),
    do: m

  def action_expected_input_keys(_), do: nil

  def action_input_field_types(%Manifest.Action{custom: %{ash_rpc: %{input_field_types: m}}}),
    do: m

  def action_input_field_types(_), do: nil
end
