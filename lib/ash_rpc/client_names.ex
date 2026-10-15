# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ClientNames do
  @moduledoc """
  Resolves client-supplied names to internal atoms by exact lookup in the
  reverse maps `AshRpc.Manifest.Decorator` precomputes with the output
  formatter.

  Pure map lookups: no formatter is called on a client string, and no atom
  is created or looked up from one. Atom names (callers that already hold
  internal names) are returned unchanged. A miss is `:error`; each caller
  decides what a miss means.
  """

  alias Ash.Info.Manifest
  alias AshRpc.Manifest.Custom
  alias AshRpc.Runtime

  @type result :: {:ok, atom()} | :error

  @spec resource_field(Runtime.t(), module(), term()) :: result()
  def resource_field(_rt, _resource, name) when is_atom(name), do: {:ok, name}

  def resource_field(rt, resource, name) when is_binary(name),
    do: rt.resource_lookup |> Map.get(resource) |> Custom.client_field_names() |> Map.fetch(name)

  def resource_field(_rt, _resource, _name), do: :error

  @spec calc_arg(Runtime.t(), module(), atom(), term()) :: result()
  def calc_arg(_rt, _resource, _calc, name) when is_atom(name), do: {:ok, name}

  def calc_arg(rt, resource, calc, name) when is_binary(name) do
    rt.resource_lookup
    |> Map.get(resource)
    |> Custom.calculation_argument_names(calc)
    |> Map.fetch(name)
  end

  def calc_arg(_rt, _resource, _calc, _name), do: :error

  @doc """
  Resolves the keys of a calculation's argument map with `calc_arg/4`. A miss
  keeps the key as sent, for the caller or Ash to reject.
  """
  @spec calc_args(Runtime.t(), module(), atom(), term()) :: term()
  def calc_args(rt, resource, calc, args) when is_map(args) do
    Map.new(args, fn {key, value} ->
      case calc_arg(rt, resource, calc, key) do
        {:ok, name} -> {name, value}
        :error -> {key, value}
      end
    end)
  end

  def calc_args(_rt, _resource, _calc, args), do: args

  @spec type_field(Runtime.t(), Manifest.Type.t(), term()) :: result()
  def type_field(_rt, _type, name) when is_atom(name), do: {:ok, name}

  def type_field(rt, %Manifest.Type{} = type, name) when is_binary(name),
    do: rt |> decorated(type) |> Custom.type_client_field_names() |> Map.fetch(name)

  def type_field(_rt, _type, _name), do: :error

  @spec union_member(Runtime.t(), Manifest.Type.t(), term()) :: result()
  def union_member(_rt, _type, name) when is_atom(name), do: {:ok, name}

  def union_member(rt, %Manifest.Type{} = type, name) when is_binary(name),
    do: rt |> decorated(type) |> Custom.type_client_member_names() |> Map.fetch(name)

  def union_member(_rt, _type, _name), do: :error

  @spec vocabulary(Runtime.t(), atom(), term()) :: result()
  def vocabulary(_rt, _scope, name) when is_atom(name), do: {:ok, name}

  def vocabulary(rt, scope, name) when is_binary(name),
    do: rt.vocabulary |> Map.get(scope, %{}) |> Map.fetch(name)

  def vocabulary(_rt, _scope, _name), do: :error

  @doc """
  Whether `resource` carries decorated client names. Input keys on a named
  resource must be client names; an undecorated one passes keys as sent.
  """
  @spec resource_named?(Runtime.t(), module()) :: boolean()
  def resource_named?(rt, resource),
    do:
      match?(
        %{custom: %{ash_rpc: %{client_field_names: _}}},
        Map.get(rt.resource_lookup, resource)
      )

  @doc """
  Whether `type` (or its type lookup entry) carries decorated field names.
  A type that never went through the decorator passes keys as sent.
  """
  @spec type_named?(Runtime.t(), Manifest.Type.t()) :: boolean()
  def type_named?(rt, %Manifest.Type{} = type),
    do: match?(%{custom: %{ash_rpc: %{client_field_names: _}}}, decorated(rt, type))

  def type_named?(_rt, _type), do: false

  # A struct without decoration (a named reference, or a copy taken before
  # decoration) resolves through the type lookup entry for its module.
  defp decorated(_rt, %Manifest.Type{custom: %{ash_rpc: _}} = type), do: type

  defp decorated(rt, %Manifest.Type{} = type) do
    case Manifest.Type.effective_module(type) do
      nil -> type
      module -> Manifest.get_type(rt.type_lookup, module) || type
    end
  end
end
