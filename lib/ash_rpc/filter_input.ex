# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FilterInput do
  @moduledoc """
  Rewrites client names in filter statements and sort strings to internal
  atoms before `Ash.Query.filter_input/2` / `Ash.Query.sort_input/2`.

  A name that is not a client name is dropped and reported as the error Ash
  raises for an unknown name (`Ash.Error.Query.NoSuchField`,
  `Ash.Error.Query.NoSuchFilterPredicate`), carrying the name as sent.
  Ash would otherwise accept an internal name the client never sees (e.g.
  `view_count` under `:camel_case`). Callers add the errors to the query.
  """

  alias Ash.Info.Manifest
  alias AshRpc.ClientNames

  @spec parse(AshRpc.Runtime.t(), module(), term()) :: {term(), [Exception.t()]}
  def parse(_rt, _resource, nil), do: {nil, []}

  def parse(rt, resource, filter) do
    {statement, errors} = walk(rt, resource, filter, [])
    {statement, Enum.reverse(errors)}
  end

  @spec parse_sort(AshRpc.Runtime.t(), module(), term()) :: {String.t() | nil, [Exception.t()]}
  def parse_sort(_rt, _resource, nil), do: {nil, []}

  def parse_sort(rt, resource, sort) when is_binary(sort),
    do: parse_sort(rt, resource, String.split(sort, ","))

  def parse_sort(rt, resource, sort) when is_list(sort) do
    {fields, errors} =
      Enum.reduce(sort, {[], []}, fn entry, {fields, errors} ->
        case sort_field(rt, resource, entry) do
          {:ok, field} -> {[field | fields], errors}
          {:error, error} -> {fields, [error | errors]}
        end
      end)

    sort_string = if fields == [], do: nil, else: fields |> Enum.reverse() |> Enum.join(",")
    {sort_string, Enum.reverse(errors)}
  end

  def parse_sort(_rt, _resource, sort), do: {sort, []}

  defp sort_field(rt, resource, entry) when is_binary(entry) do
    {modifier, name} = split_modifier(entry)

    case ClientNames.resource_field(rt, resource, name) do
      {:ok, field} -> {:ok, modifier <> Atom.to_string(field)}
      :error -> {:error, no_such_field(resource, name, :sort)}
    end
  end

  defp sort_field(_rt, _resource, entry), do: {:ok, to_string(entry)}

  defp split_modifier("++" <> name), do: {"++", name}
  defp split_modifier("--" <> name), do: {"--", name}
  defp split_modifier("+" <> name), do: {"+", name}
  defp split_modifier("-" <> name), do: {"-", name}
  defp split_modifier(name), do: {"", name}

  # Resource level: field and relationship names, and and/or/not.
  defp walk(rt, resource, filter, errors) when is_map(filter) and not is_struct(filter) do
    Enum.reduce(filter, {%{}, errors}, fn {key, value}, {acc, errors} ->
      case resource_entry(rt, resource, key, value, errors) do
        {:keep, name, value, errors} -> {Map.put(acc, name, value), errors}
        {:drop, errors} -> {acc, errors}
      end
    end)
  end

  defp walk(rt, resource, list, errors) when is_list(list) do
    {items, errors} =
      Enum.reduce(list, {[], errors}, fn item, {items, errors} ->
        {item, errors} = walk(rt, resource, item, errors)
        {[item | items], errors}
      end)

    {Enum.reverse(items), errors}
  end

  defp walk(_rt, _resource, other, errors), do: {other, errors}

  defp resource_entry(rt, resource, key, value, errors) do
    res = Map.get(rt.resource_lookup, resource)

    with {:ok, name} <- ClientNames.resource_field(rt, resource, key),
         {:ok, kind} <- field_kind(res, name) do
      {value, errors} = entry_value(rt, resource, name, kind, value, errors)
      {:keep, name, value, errors}
    else
      _ -> boolean_entry(rt, resource, key, value, errors)
    end
  end

  defp boolean_entry(rt, resource, key, value, errors) do
    case ClientNames.vocabulary(rt, :filter_ops, key) do
      {:ok, op} when op in [:and, :or, :not] ->
        {value, errors} = walk(rt, resource, value, errors)
        {:keep, op, value, errors}

      _ when is_binary(key) ->
        {:drop, [no_such_field(resource, key, :filter) | errors]}

      _ ->
        {:keep, key, value, errors}
    end
  end

  # Fields take precedence over relationships, as in field selection.
  defp field_kind(%Manifest.Resource{} = res, name) do
    case Map.get(res.fields, name) do
      %Manifest.Field{kind: kind} ->
        {:ok, kind}

      nil ->
        case Map.get(res.relationships, name) do
          %Manifest.Relationship{destination: dest} -> {:ok, {:relationship, dest}}
          nil -> :error
        end
    end
  end

  defp field_kind(_res, _name), do: :error

  defp entry_value(rt, _resource, _name, {:relationship, dest}, value, errors),
    do: walk(rt, dest, value, errors)

  defp entry_value(rt, resource, name, :calculation, value, errors),
    do: walk_ops(rt, resource, name, value, errors)

  defp entry_value(rt, resource, _name, _kind, value, errors),
    do: walk_ops(rt, resource, nil, value, errors)

  # Operator level: keys are operator/function names, or `input` for a
  # calculation's arguments. Right-hand sides are left as sent.
  defp walk_ops(rt, resource, calc, ops, errors) when is_map(ops) and not is_struct(ops) do
    Enum.reduce(ops, {%{}, errors}, fn {key, value}, {acc, errors} ->
      case ClientNames.vocabulary(rt, :filter_ops, key) do
        {:ok, :input} when not is_nil(calc) ->
          {Map.put(acc, :input, ClientNames.calc_args(rt, resource, calc, value)), errors}

        {:ok, op} ->
          {Map.put(acc, op, value), errors}

        :error ->
          {acc, [no_such_predicate(resource, key) | errors]}
      end
    end)
  end

  defp walk_ops(_rt, _resource, _calc, value, errors), do: {value, errors}

  defp no_such_field(resource, name, path),
    do: Ash.Error.Query.NoSuchField.exception(resource: resource, field: name, path: [path])

  defp no_such_predicate(resource, key),
    do:
      Ash.Error.Query.NoSuchFilterPredicate.exception(
        resource: resource,
        key: key,
        path: [:filter]
      )
end
