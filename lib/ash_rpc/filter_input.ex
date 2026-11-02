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
  `view_count` under `:camel_case`).

  Operator values are formatted as client input with the type the field's
  operator takes (its manifest `rhs`), so structured values (embedded
  resources, typed maps and structs, unions) get internal keys. A value
  `AshRpc.ValueFormatter.format_input/3` rejects drops its operator and is
  reported as `AshRpc.FilterInput.InvalidValue`, one per reason. Callers add
  the errors to the query.
  """

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Type
  alias AshRpc.{ClientNames, ValueFormatter}
  alias AshRpc.FilterInput.InvalidValue

  @spec parse(AshRpc.Runtime.t(), module(), term()) :: {term(), [Exception.t()]}
  def parse(_rt, _resource, nil), do: {nil, []}

  def parse(rt, resource, filter) do
    {statement, errors} = walk(rt, resource, filter, [:filter], [])
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

  # Resource level: field and relationship names, and and/or/not. `path` is
  # where the node sits in the request, keys as sent (for value errors).
  defp walk(rt, resource, filter, path, errors) when is_map(filter) and not is_struct(filter) do
    Enum.reduce(filter, {%{}, errors}, fn {key, value}, {acc, errors} ->
      case resource_entry(rt, resource, key, value, path ++ [key], errors) do
        {:keep, name, value, errors} -> {Map.put(acc, name, value), errors}
        {:drop, errors} -> {acc, errors}
      end
    end)
  end

  defp walk(rt, resource, list, path, errors) when is_list(list) do
    {items, errors} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], errors}, fn {item, index}, {items, errors} ->
        {item, errors} = walk(rt, resource, item, path ++ [index], errors)
        {[item | items], errors}
      end)

    {Enum.reverse(items), errors}
  end

  defp walk(_rt, _resource, other, _path, errors), do: {other, errors}

  defp resource_entry(rt, resource, key, value, path, errors) do
    res = Map.get(rt.resource_lookup, resource)

    with {:ok, name} <- ClientNames.resource_field(rt, resource, key),
         {:ok, entry} <- field_or_relationship(res, name) do
      {value, errors} = entry_value(rt, resource, entry, value, path, errors)
      {:keep, name, value, errors}
    else
      _ -> boolean_entry(rt, resource, key, value, path, errors)
    end
  end

  defp boolean_entry(rt, resource, key, value, path, errors) do
    case ClientNames.vocabulary(rt, :filter_ops, key) do
      {:ok, op} when op in [:and, :or, :not] ->
        {value, errors} = walk(rt, resource, value, path, errors)
        {:keep, op, value, errors}

      _ when is_binary(key) ->
        {:drop, [no_such_field(resource, key, :filter) | errors]}

      _ ->
        {:keep, key, value, errors}
    end
  end

  # Fields take precedence over relationships, as in field selection.
  defp field_or_relationship(%Manifest.Resource{} = res, name) do
    case Map.get(res.fields, name) do
      %Manifest.Field{} = field ->
        {:ok, field}

      nil ->
        case Map.get(res.relationships, name) do
          %Manifest.Relationship{destination: dest} -> {:ok, {:relationship, dest}}
          nil -> :error
        end
    end
  end

  defp field_or_relationship(_res, _name), do: :error

  defp entry_value(rt, _resource, {:relationship, dest}, value, path, errors),
    do: walk(rt, dest, value, path, errors)

  defp entry_value(rt, resource, %Manifest.Field{} = field, value, path, errors),
    do: walk_ops(rt, resource, field, value, path, errors)

  # Operator level: keys are operator/function names, or `input` for a
  # calculation's arguments. Each right-hand side is formatted as input with
  # the type the field's operator takes (`rhs`).
  defp walk_ops(rt, resource, field, ops, path, errors) when is_map(ops) and not is_struct(ops) do
    Enum.reduce(ops, {%{}, errors}, fn {key, value}, {acc, errors} ->
      case ClientNames.vocabulary(rt, :filter_ops, key) do
        {:ok, :input} when field.kind == :calculation ->
          {Map.put(acc, :input, ClientNames.calc_args(rt, resource, field.name, value)), errors}

        {:ok, op} ->
          case format_rhs(rt, field, op, value) do
            {:ok, value} ->
              {Map.put(acc, op, value), errors}

            {:error, reasons} ->
              {acc, invalid_values(reasons, path ++ [key], errors)}
          end

        :error ->
          {acc, [no_such_predicate(resource, key) | errors]}
      end
    end)
  end

  defp walk_ops(_rt, _resource, _field, value, _path, errors), do: {value, errors}

  defp format_rhs(rt, field, op, value) do
    case rhs_type(rhs(field, op), same_type(field, op)) do
      %Type{} = type -> ValueFormatter.format_input(value, type, rt)
      nil -> {:ok, value}
    end
  end

  # The manifest names operators by symbol (`:==`) and functions by name; the
  # filter key is a predicate name or alias (`:eq`, `:equals`).
  defp rhs(%Manifest.Field{} = field, op) do
    name =
      case Ash.Filter.get_operator(op) do
        nil -> op
        operator -> operator.operator()
      end

    Enum.find_value(
      List.wrap(field.filter_operators) ++ List.wrap(field.filter_functions),
      fn applicable -> if applicable.name == name, do: applicable.rhs end
    )
  end

  # `:same` is the field's type, except for `has`, whose field is the array
  # (`{:array, :same}`) and whose value is one element.
  defp same_type(%Manifest.Field{type: %Type{item_type: item_type}}, :has), do: item_type
  defp same_type(%Manifest.Field{type: type}, _op), do: type

  defp rhs_type(rhs, same) when rhs in [:same, :any], do: same
  defp rhs_type({:array, inner}, same), do: array_of(rhs_type(inner, same))
  defp rhs_type(_rhs, _same), do: nil

  defp array_of(nil), do: nil
  defp array_of(%Type{} = item), do: %Type{kind: :array, item_type: item, constraints: []}

  defp invalid_values(reasons, path, errors) do
    Enum.reduce(reasons, errors, fn reason, errors ->
      [InvalidValue.exception(reason: reason, path: path) | errors]
    end)
  end

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
