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
  `view_count` under `:camel_case`). A relationship to a resource the mapping
  source doesn't expose is unknown too, as in field selection.

  Operator values are formatted as client input with the type the field's
  operator takes (its manifest `rhs`), so structured values (embedded
  resources, typed maps and structs, unions) get internal keys. A bare value
  on a field is `eq` and is formatted the same way. A calculation's `input`
  takes internal argument names, and each value is formatted with its
  argument's type. A value `AshRpc.ValueFormatter.format_input/3` rejects
  drops its operator (the field, for a bare value or a calculation `input`)
  and is reported as `AshRpc.FilterInput.InvalidValue`, one per reason; so is
  an `input` argument name that is not a client name, an `in` value that is
  not a list, and a value an operator's concrete type (`isNil`, `contains`)
  can't cast. A calculation's arguments are checked as Ash would (required,
  cast, constraints), with or without an `input`, so the error carries the
  full path; Ash's own has only `[:filter]`.

  A statement (the filter, a list entry, an `and`/`or`/`not` operand, a
  relationship's condition) that is a string, number or null, a
  relationship's condition that is a boolean, an empty `and`/`or`, and a
  calculation `input` that is not a map are dropped and reported as
  `InvalidValue` too.

  A sort that is not a string or a list, and a list entry that is not a string
  (or an atom, an internal name), is reported as `Ash.Error.Query.InvalidSort`;
  a relationship, a calculation with required arguments and a field the
  manifest marks unsortable as `Ash.Error.Query.UnsortableField`.
  Callers add the errors to the query.
  """

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Type
  alias AshRpc.{ClientNames, ValueFormatter}
  alias AshRpc.FilterInput.InvalidValue
  alias AshRpc.Manifest.Custom

  @spec parse(AshRpc.Runtime.t(), module(), term()) :: {term(), [Exception.t()]}
  def parse(_rt, _resource, nil), do: {nil, []}

  def parse(rt, resource, filter) do
    case walk(rt, resource, filter, [:filter], []) do
      {:drop, errors} -> {nil, Enum.reverse(errors)}
      {statement, errors} -> {statement, Enum.reverse(errors)}
    end
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

  def parse_sort(_rt, _resource, sort), do: {nil, [invalid_sort(sort)]}

  defp sort_field(rt, resource, entry) when is_binary(entry) do
    {modifier, name} = split_modifier(entry)

    with {:ok, field} <- ClientNames.resource_field(rt, resource, name),
         :ok <- sortable(rt, Map.get(rt.resource_lookup, resource), field, name) do
      {:ok, modifier <> Atom.to_string(field)}
    else
      :error -> {:error, no_such_field(resource, name, [:sort])}
      {:error, _} = error -> error
    end
  end

  # An atom is an internal name from a server-side caller.
  defp sort_field(_rt, _resource, entry) when is_atom(entry) and not is_nil(entry),
    do: {:ok, Atom.to_string(entry)}

  defp sort_field(_rt, _resource, entry), do: {:error, invalid_sort(entry)}

  defp invalid_sort(sort), do: Ash.Error.Query.InvalidSort.exception(sort: sort, path: [:sort])

  # Ash would reject these with internal names in its message. A relationship
  # to a resource the mapping source doesn't expose is unknown, as in filters.
  defp sortable(rt, %Manifest.Resource{} = res, field, name) do
    case {Map.get(res.fields, field), Map.get(res.relationships, field)} do
      {%Manifest.Field{sortable?: false}, _} ->
        {:error, unsortable(res, name, nil)}

      {%Manifest.Field{kind: :calculation} = calc, _} ->
        if Enum.any?(calc.arguments || [], &required_argument?/1),
          do: {:error, unsortable(res, name, :requires_arguments)},
          else: :ok

      {nil, %Manifest.Relationship{destination: dest}} ->
        if Custom.exposed?(Map.get(rt.resource_lookup, dest)),
          do: {:error, unsortable(res, name, :relationship)},
          else: :error

      _ ->
        :ok
    end
  end

  defp sortable(_rt, _res, _field, _name), do: :ok

  defp unsortable(res, name, reason),
    do:
      Ash.Error.Query.UnsortableField.exception(
        resource: res.module,
        field: name,
        reason: reason,
        path: [:sort]
      )

  defp required_argument?(%Manifest.Argument{} = arg),
    do: arg.allow_nil? == false and not arg.has_default?

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
        case walk(rt, resource, item, path ++ [index], errors) do
          {:drop, errors} -> {items, errors}
          {item, errors} -> {[item | items], errors}
        end
      end)

    # A list whose every entry was dropped is dropped too: Ash rejects `[]`
    # under and/or.
    if items == [] and list != [], do: {:drop, errors}, else: {Enum.reverse(items), errors}
  end

  # A statement is a map or a list; a string, number or null is dropped and
  # reported. Booleans, keyword tuples and structs pass to Ash.
  defp walk(_rt, _resource, other, path, errors)
       when is_binary(other) or is_number(other) or is_nil(other),
       do: {:drop, [invalid_statement(path) | errors]}

  defp walk(_rt, _resource, other, _path, errors), do: {other, errors}

  defp resource_entry(rt, resource, key, value, path, errors) do
    res = Map.get(rt.resource_lookup, resource)

    with {:ok, name} <- ClientNames.resource_field(rt, resource, key),
         {:ok, entry} <- field_or_relationship(rt, res, name) do
      case entry_value(rt, resource, entry, value, path, errors) do
        {:drop, errors} -> {:drop, errors}
        {value, errors} -> {:keep, name, value, errors}
      end
    else
      _ -> boolean_entry(rt, resource, key, value, path, errors)
    end
  end

  defp boolean_entry(rt, resource, key, value, path, errors) do
    case ClientNames.vocabulary(rt, :filter_ops, key) do
      # Ash rejects an empty and/or.
      {:ok, op} when op in [:and, :or] and value in [[], %{}] ->
        {:drop, [invalid_statement(path) | errors]}

      {:ok, op} when op in [:and, :or, :not] ->
        case walk(rt, resource, value, path, errors) do
          {:drop, errors} -> {:drop, errors}
          {value, errors} -> {:keep, op, value, errors}
        end

      # Reported where the field sits, like an unknown operator.
      _ when is_binary(key) ->
        {:drop, [no_such_field(resource, key, Enum.drop(path, -1)) | errors]}

      _ ->
        {:keep, key, value, errors}
    end
  end

  # Fields take precedence over relationships, as in field selection. A
  # relationship to a resource the mapping source doesn't expose is unknown,
  # as in field selection.
  defp field_or_relationship(rt, %Manifest.Resource{} = res, name) do
    case Map.get(res.fields, name) do
      %Manifest.Field{} = field ->
        {:ok, field}

      nil ->
        with %Manifest.Relationship{destination: dest} <- Map.get(res.relationships, name),
             true <- Custom.exposed?(Map.get(rt.resource_lookup, dest)) do
          {:ok, {:relationship, dest}}
        else
          _ -> :error
        end
    end
  end

  defp field_or_relationship(_rt, _res, _name), do: :error

  # A relationship's condition is a statement. Ash would take any other value
  # (a boolean) as a primary key.
  defp entry_value(_rt, _resource, {:relationship, _dest}, value, path, errors)
       when not is_map(value) and not is_list(value),
       do: {:drop, [invalid_statement(path) | errors]}

  defp entry_value(rt, _resource, {:relationship, dest}, value, path, errors),
    do: walk(rt, dest, value, path, errors)

  defp entry_value(rt, resource, %Manifest.Field{} = field, value, path, errors),
    do: walk_ops(rt, resource, field, value, path, errors)

  # Operator level: keys are operator/function names, or `input` for a
  # calculation's arguments. Each right-hand side is formatted as input with
  # the type the field's operator takes (`rhs`).
  # A rejected calculation `input` drops the whole field: no operator on the
  # calculation means anything without it. So does a missing required
  # argument when there is no `input`.
  defp walk_ops(rt, resource, field, ops, path, errors) when is_map(ops) and not is_struct(ops) do
    {ops, errors, keep?} =
      Enum.reduce(ops, {%{}, errors, true}, fn {key, value}, {acc, errors, keep?} ->
        case ClientNames.vocabulary(rt, :filter_ops, key) do
          {:ok, :input} when field.kind == :calculation ->
            case calculation_input(rt, resource, field, value, path ++ [key]) do
              {:ok, input} -> {Map.put(acc, :input, input), errors, keep?}
              {:error, input_errors} -> {acc, Enum.reverse(input_errors, errors), false}
            end

          {:ok, :input} ->
            {acc, [no_such_predicate(resource, key, path) | errors], keep?}

          {:ok, op} ->
            case format_rhs(rt, field, op, value) do
              {:ok, value} ->
                {Map.put(acc, op, value), errors, keep?}

              {:error, reasons} ->
                {acc, invalid_values(reasons, path ++ [key], errors), keep?}
            end

          :error ->
            {acc, [no_such_predicate(resource, key, path) | errors], keep?}
        end
      end)

    input_errors = if keep?, do: missing_input_errors(rt, resource, field, ops, path), else: []

    cond do
      not keep? -> {:drop, errors}
      input_errors != [] -> {:drop, Enum.reverse(input_errors, errors)}
      true -> {ops, errors}
    end
  end

  # Any other value is the shorthand for `eq` (as in Ash), formatted the same
  # way; a rejected value drops the field. Maps (structs) and keyword lists are
  # operators from server-side callers and pass through.
  defp walk_ops(rt, resource, field, value, path, errors)
       when not is_map(value) and not (is_list(value) and value != [] and is_tuple(hd(value))) do
    with {:ok, value} <- format_rhs(rt, field, :eq, value),
         [] <- missing_input_errors(rt, resource, field, %{}, path) do
      {value, errors}
    else
      {:error, reasons} -> {:drop, invalid_values(reasons, path, errors)}
      input_errors -> {:drop, Enum.reverse(input_errors, errors)}
    end
  end

  defp walk_ops(_rt, _resource, _field, value, _path, errors), do: {value, errors}

  # Argument names resolve by client name and values are formatted with each
  # argument's type. A name that is not a client name, or a value
  # format_input/3 rejects, is reported under `path`.
  defp calculation_input(_rt, _resource, _field, input, path)
       when not is_map(input) or is_struct(input),
       do: {:error, [InvalidValue.exception(reason: :invalid_calculation_input, path: path)]}

  defp calculation_input(rt, resource, field, input, path) do
    {input, value_errors} = ValueFormatter.format_calculation_args(rt, resource, field, input)

    name_errors =
      for key <- unresolved_keys(input),
          do: InvalidValue.exception(reason: {:unknown_input, key, []}, path: path)

    errors =
      name_errors ++
        Enum.map(value_errors, fn {key, reason} ->
          InvalidValue.exception(reason: reason, path: path ++ [key])
        end)

    errors = if errors == [], do: argument_errors(rt, resource, field, input, path), else: errors

    if errors == [], do: {:ok, input}, else: {:error, errors}
  end

  # A calculation without `input` still needs its required arguments. Reported
  # at the `input` the client should send.
  defp missing_input_errors(rt, resource, %Manifest.Field{kind: :calculation} = field, ops, path)
       when not is_map_key(ops, :input),
       do: argument_errors(rt, resource, field, %{}, path ++ [:input])

  defp missing_input_errors(_rt, _resource, _field, _ops, _path), do: []

  # What Ash checks for each argument (a missing required one, a value its
  # type can't cast or whose constraints fail), checked here so the error
  # carries the argument's path. Ash's own error has only `[:filter]`.
  defp argument_errors(rt, resource, field, input, path) do
    client_names =
      rt.resource_lookup
      |> Map.get(resource)
      |> Custom.calculation_argument_names(field.name)
      |> Map.new(fn {client, internal} -> {internal, client} end)

    for arg <- field.arguments || [],
        problem = argument_problem(arg, input),
        problem != nil do
      name = Map.get(client_names, arg.name, Atom.to_string(arg.name))
      InvalidValue.exception(reason: {:invalid_calculation_argument, name, problem}, path: path)
    end
  end

  defp argument_problem(arg, input) do
    case Map.fetch(input, arg.name) do
      :error -> if required_argument?(arg), do: :required
      {:ok, nil} -> if arg.allow_nil? == false, do: :required
      {:ok, value} -> cast_problem(arg, value)
    end
  end

  defp cast_problem(arg, value) do
    case ash_type(arg.type) do
      {type, constraints} ->
        with {:ok, casted} <- Ash.Type.cast_input(type, value, constraints),
             {:ok, casted} <- Ash.Type.apply_constraints(type, casted, constraints) do
          if is_nil(casted) and arg.allow_nil? == false, do: :required
        else
          _ -> :invalid
        end

      nil ->
        nil
    end
  end

  # The Ash type and constraints a manifest type stands for.
  defp ash_type(%Type{kind: :array, item_type: %Type{} = item} = type) do
    with {item_type, item_constraints} <- ash_type(item),
         do: {{:array, item_type}, Keyword.put(type.constraints || [], :items, item_constraints)}
  end

  defp ash_type(%Type{module: module, constraints: constraints}) when not is_nil(module),
    do: {module, constraints || []}

  defp ash_type(_type), do: nil

  defp unresolved_keys(input), do: input |> Map.keys() |> Enum.filter(&is_binary/1)

  # A list operator (`in`) takes a list, and an operator with a concrete
  # right-hand type (`isNil`, `contains`) a value of that type; Ash's error for
  # either names internals. Values of the field's own type are formatted.
  defp format_rhs(rt, field, op, value) do
    rhs = rhs(field, op)

    case {rhs, rhs_type(rhs, same_type(field, op))} do
      {{:array, _}, _} when not is_list(value) ->
        {:error, [{:invalid_filter_value, "A list"}]}

      {{:concrete, module}, _} ->
        concrete_value(module, value)

      {_, %Type{} = type} ->
        ValueFormatter.format_input(value, type, rt)

      {_, nil} ->
        {:ok, value}
    end
  end

  defp concrete_value(module, value) do
    case Ash.Type.cast_input(module, value, []) do
      {:ok, _} -> {:ok, value}
      _ -> {:error, [{:invalid_filter_value, "A #{type_name(module)} value"}]}
    end
  end

  defp type_name(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore() |> String.replace("_", " ")

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

  defp invalid_statement(path),
    do: InvalidValue.exception(reason: :invalid_filter_statement, path: path)

  # `path` is where the field sits: `[:sort]`, or the filter path down to its
  # parent, keys as sent.
  defp no_such_field(resource, name, path),
    do: Ash.Error.Query.NoSuchField.exception(resource: resource, field: name, path: path)

  # `path` is the field's, like InvalidValue's.
  defp no_such_predicate(resource, key, path),
    do: Ash.Error.Query.NoSuchFilterPredicate.exception(resource: resource, key: key, path: path)
end
