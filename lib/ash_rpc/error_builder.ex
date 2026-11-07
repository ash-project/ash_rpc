# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorBuilder do
  @moduledoc """
  Comprehensive error handling and message generation for the RPC pipeline.

  Provides clear, actionable error messages for all failure modes with
  detailed context for debugging and client consumption.

  ## Error types

  Each pipeline reason becomes an error map whose `type` is one of the
  following. Types marked *(hint)* can be caused by a client built against an
  older manifest, and carry the profile's `stale_client_hint/0` in
  `details.hint`. The others are request shapes a conforming client never sends.

  Action and parameters:

  - `action_not_found` *(hint)*: the `action` param names no entrypoint.
  - `missing_required_parameter` *(hint)*: the `action` or `fields` param is
    missing or empty.
  - `invalid_action_type`: `action` is not a string.
  - `invalid_tenant_type`: `tenant` is not a string, an integer or an atom.
    The message asks for a string or an integer: atoms come only from
    server-side callers.
  - `invalid_input_format`: `input` is not a map.
  - `unknown_input` *(hint)*: an `input` key is not one of the action's
    client input names, or a nested key is not a client name of its type
    (`path` locates it). One error per key.
  - `invalid_metadata_fields_type`: `metadataFields` is not a list.
  - `unknown_metadata_fields` *(hint)*: a `metadataFields` entry is not the
    client name of a metadata field the entrypoint exposes. One error lists
    every miss in `fields` and the allowed names in `details.allowedFields`.

  Field selection:

  - `invalid_fields_type`: `fields` is not a list (on any action that is
    sent it).
  - `empty_fields_array`: `fields` is an empty list.
  - `unknown_field` *(hint)*: the field is not a public field of the resource
    or typed value, the relationship's destination is not exposed, or a
    `fields` entry is neither a name nor a `{name: spec}` map.
  - `unknown_map_field` *(hint)*: the field is not in a map type's `fields`
    constraints.
  - `unknown_union_field` *(hint)*: the name is not a member of the union.
  - `requires_field_selection` *(hint)*: a relationship, embedded resource,
    union or typed value was requested without a nested field list, or with an
    empty one.
  - `invalid_field_selection` *(hint)*: a nested field list was given for an
    aggregate or calculation with a primitive type, or for an action whose
    return type is primitive. Also, without the hint: a calculation selected in
    a value that isn't loaded through (an aggregate's, or a field's of a
    typed map or struct).
  - `field_does_not_support_nesting` *(hint)*: a nested specification was
    given for a primitive attribute or calculation.
  - `unsupported_field_combination` *(hint)*: a relationship's nested
    specification is not a list.
  - `duplicate_field`: the same field is requested more than once at one level.
  - `invalid_field_format` *(hint)*: `args` were given inside a typed value,
    tuple or union member, or a calculation that requires arguments was
    selected by name only.
  - `invalid_calculation_args` *(hint)*: a calculation's `args` are not a map,
    are missing or empty when required, given to a calculation that takes
    none, contain a key the calculation doesn't define, or are replaced by a
    nested field map. Without the hint: a calculation `input` in a filter is
    not a map (`path` ends at `input`).
  - `invalid_calculation_argument`: a calculation argument in a filter is
    missing when required (`is required`) or its type rejects the value (`is
    invalid`); `fields` names the argument, `path` ends at the calculation's
    `input` (whether or not one was sent). The same type comes from Ash for
    field selection `args`.
  - `unknown_input` *(hint)* / `invalid_union_input`: a calculation argument's
    value has a key that is not a client name of its type, or is a malformed
    union value. `path` runs through the calculation, `args` and the argument.

  Union input:

  - `invalid_union_input`: a union input is not a map *(hint)*, contains no
    member key *(hint)*, or contains more than one member key.

  Load restrictions:

  - `load_not_allowed` *(hint)*: a requested load is outside the entrypoint's
    `{:allow, paths}` restriction.
  - `load_denied` *(hint)*: a requested load is inside the entrypoint's
    `{:deny, paths}` restriction.

  Query options:

  - `filter_not_supported` / `sort_not_supported` *(hint)*: `filter` / `sort`
    sent where the entrypoint disables it (`details.reason` `disabled`), or to a
    non-list action or a relationship that isn't filterable/sortable
    (`unsupported`).
  - `pagination_not_supported` *(hint)*: `page` sent to a non-list action or
    an action without pagination, or a nested `page` on a relationship whose
    read action has no pagination.
  - `invalid_pagination`: `page` is not a map or has unknown keys. *(hint)*
    when a nested relationship `page` is not a map or has keys its pagination
    type rejects.
  - `invalid_query_opts`: a query-option envelope on a field that is not a
    has_many/many_to_many relationship *(hint)*, `args` combined with query
    options, `page` combined with bare `limit`/`offset`, a bare `limit` /
    `offset` that is not a non-negative integer (`path` ends at the key), or
    a relationship envelope key that is not an envelope option (`vars.keys`
    as sent, `path` ends at the relationship).
  - `invalid_filter`: a filter statement (the `filter` param, a list entry,
    an `and`/`or`/`not` operand or a relationship's condition) is a string,
    number, boolean or null, or an `and`/`or` is empty. `path` locates it.
  - `invalid_filter_value`: an operator value has the wrong shape: a list
    operator (`in`) given a non-list (`details.expected` `A list`), or a value
    an operator's own type (`isNil`, `contains`) can't cast (`A boolean
    value`, `A string value`), a value the field's type can't cast, or a
    structured one whose constraints fail (`A value of the field's type`), or
    a union value of a member that is a record (`A value of a union member
    that is not a record`). `path` ends at the operator. The same type, with `path`
    `filter` and no `details.expected`, comes from a value Ash itself
    rejects.

  Identity and `getBy`:

  - `missing_identity` *(hint)*: an action that requires an `identity` got
    none.
  - `invalid_identity`: the `identity` keys match no configured identity
    *(hint)*, a primary key was sent where the action has no primary-key
    identity, or an identity value is not a scalar.
  - `missing_required_input` *(hint)*: required `getBy` fields are missing.
  - `unexpected_get_by_fields` *(hint)*: `getBy` contains fields the
    entrypoint does not allow.
  - `get_by_not_supported` *(hint)*: `getBy` sent (an empty map included) to
    an entrypoint that declares no `get_by` fields.
  - `invalid_get_by`: `getBy` is not a map, or a `getBy` value is not a
    scalar.

  Results:

  - `invalid_union_return`: a generic action declared to return a union (or
    an array of unions) returned a value, or an item, that is not an
    `%Ash.Union{}`. A server-side bug, not a request error.

  Fallbacks:

  - `internal_error`: a non-map reason no clause recognises. The client gets
    only a generic message and `errorId`; the term is logged server-side under
    that id, never sent. A map or struct goes through
    `AshRpc.Errors.to_errors/6` like an exception.

  Exceptions and Ash errors are not pipeline reasons. They go through
  `AshRpc.Errors.to_errors/6`, and their `type` comes from the `AshRpc.Error`
  protocol impl (or is the underscored exception name).
  """

  alias AshRpc.{ClientPath, Errors, FieldFormatter}

  @doc """
  Builds a detailed error response from various error types.

  Converts internal error tuples into structured error responses
  with clear messages and debugging context.

  For Ash framework errors, uses the new Error protocol for standardized extraction.

  Returns either a single error map or a list of error maps (for Ash errors with multiple sub-errors).

  `scope` is `nil` or `%{domain:, resource:, action:, context:}`; Ash errors are
  routed through `AshRpc.Errors.to_errors/6` with it, so the profile's domain
  error handling applies to execution errors too. An optional `selection:` key
  is where field-selection paths start (the entrypoint's resource, or a generic
  action's return type); their `path` and dotted field name then take the
  decorated client names on the way. Without it atoms use the formatter.
  """
  @spec build_error_response(AshRpc.Runtime.t(), term(), map() | nil) :: map() | list(map())
  def build_error_response(runtime, error, scope \\ nil) do
    error |> build(context(runtime, scope)) |> drop_nil_hint()
  end

  @doc false
  # The error a `AshRpc.ValueFormatter.format_input/3` reason gets, moved under
  # `prefix` (atoms take the formatter, strings and indexes are kept as sent).
  # An unknown key's own path within the value is appended to the prefix.
  @spec input_error_at(AshRpc.Runtime.t(), term(), list()) :: map()
  def input_error_at(runtime, reason, prefix) do
    reason |> build_at(prefix, context(runtime, nil)) |> drop_nil_hint()
  end

  defp build_at({:unknown_input, key, rel_path}, prefix, ctx),
    do: build({:unknown_input, key, prefix ++ rel_path}, ctx)

  defp build_at(reason, prefix, ctx),
    do: reason |> build(ctx) |> Map.put(:path, Enum.map(prefix, &path_segment(&1, ctx.formatter)))

  defp context(runtime, scope) do
    %{
      runtime: runtime,
      scope: scope,
      formatter: runtime.output_formatter,
      selection: (scope && scope[:selection]) || :none,
      hint: Errors.stale_client_hint(runtime)
    }
  end

  # Error constructors. `drift/5` marks errors a client generated from an older
  # manifest could cause and attaches the profile's stale-client hint;
  # `malformed/4` marks request shapes a generated client never sends.

  defp drift(ctx, type, message, short_message, opts) do
    details = opts |> Keyword.get(:details, %{}) |> Map.put(:hint, ctx.hint)
    malformed(type, message, short_message, Keyword.put(opts, :details, details))
  end

  defp malformed(type, message, short_message, opts) do
    %{
      type: type,
      message: message,
      short_message: short_message,
      vars: Keyword.get(opts, :vars, %{}),
      path: Keyword.get(opts, :path, []),
      fields: Keyword.get(opts, :fields, []),
      details: Keyword.get(opts, :details, %{})
    }
  end

  # The `vars.field` / `fields` / `path` triple shared by field-level errors.
  # The path is a field-selection path: it and the trailing field are named
  # through the decorated manifest from the selection root.
  defp field_opts(path, field, ctx, extra_vars \\ %{}) do
    {client_path, leaf} = ClientPath.resolve(path, ctx.selection, ctx.runtime)
    full_field_path = Enum.join(client_path ++ [ClientPath.name(leaf, field, ctx.runtime)], ".")

    [
      vars: Map.put(extra_vars, :field, full_field_path),
      path: client_path,
      fields: [full_field_path]
    ]
  end

  # A load-restriction path: an internal selection path is named from the
  # selection root and dotted; a string is kept as given.
  defp load_path(path, ctx) when is_list(path),
    do: path |> selection_path(ctx) |> Enum.join(".")

  defp load_path(path, _ctx), do: path

  defp selection_path(path, ctx),
    do: path |> ClientPath.resolve(ctx.selection, ctx.runtime) |> elem(0)

  # A request param of the wrong JSON type: `path` is the param's client name,
  # `vars.received` the value as inspected.
  defp param_type_error(ctx, param, type, must_be, received, opts) do
    name = param_name(param, ctx.formatter)

    malformed(
      type,
      "#{name} parameter must be #{must_be}",
      Keyword.get(opts, :short_message, "Invalid #{name} type"),
      vars: %{received: inspect(received)},
      path: [name],
      details: %{expected: Keyword.fetch!(opts, :expected)}
    )
  end

  # Action discovery errors
  defp build({:action_not_found, action_name}, ctx) do
    drift(ctx, "action_not_found", "RPC action %{action_name} not found", "Action not found",
      vars: %{action_name: action_name},
      details: suggestion_details(action_not_found_suggestion(ctx.runtime))
    )
  end

  # === FIELD VALIDATION ERRORS WITH FIELD PATHS ===

  # Unknown field errors
  defp build({:unknown_field, field, "map", path}, ctx) when is_list(path) do
    drift(
      ctx,
      "unknown_map_field",
      "Unknown field %{field} for map return type",
      "Unknown map field",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion: "Check that the field name is valid for the map's field constraints"
          }
        ]
    )
  end

  defp build({:unknown_field, field, "union_attribute", path}, ctx) when is_list(path) do
    drift(
      ctx,
      "unknown_union_field",
      "Unknown union member %{field}",
      "Unknown union member",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion:
              "Check that the union member name is valid for the union attribute definition"
          }
        ]
    )
  end

  defp build({:unknown_field, field, kind, path}, ctx) when is_binary(kind) and is_list(path) do
    drift(
      ctx,
      "unknown_field",
      "Unknown field %{field} for %{kind} type",
      "Unknown field",
      field_opts(path, field, ctx, %{
        kind: kind |> String.trim_trailing("_type") |> String.replace("_", " ")
      }) ++
        [
          details: %{
            suggestion: "Check that the field name is valid for the type's field constraints"
          }
        ]
    )
  end

  # The resource (third element) is internal: `path` already names where the
  # field was looked up.
  defp build({:unknown_field, field, _resource, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "unknown_field",
      "Unknown field %{field}",
      "Unknown field",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion:
              "Check the field name spelling and ensure it's a public attribute, calculation, or relationship"
          }
        ]
    )
  end

  # Calculation errors
  defp build({:calculation_requires_args, field, path}, ctx) when is_list(path) do
    {_client_path, leaf} = ClientPath.resolve(path, ctx.selection, ctx.runtime)
    name = ClientPath.name(leaf, field, ctx.runtime)
    args = param_name(:args, ctx.formatter)

    drift(
      ctx,
      "invalid_field_format",
      "Calculation %{field} requires arguments",
      "Calculation requires arguments",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion: "Provide arguments in the format: {\"#{name}\": {\"#{args}\": {...}}}"
          }
        ]
    )
  end

  # Invalid field specification format (e.g. calculation args where they are not supported)
  defp build({:invalid_field_format, field_spec, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "invalid_field_format",
      "Invalid field specification format",
      "Invalid field format",
      path: selection_path(path, ctx),
      details: %{
        field_spec: inspect(field_spec),
        suggestion: "Check the documentation for valid field specification formats"
      }
    )
  end

  defp build({:invalid_calculation_args, field, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "invalid_calculation_args",
      "Invalid arguments for calculation %{field}",
      "Invalid calculation arguments",
      field_opts(path, field, ctx) ++
        [details: %{expected: "Map containing argument values or valid field selection format"}]
    )
  end

  # A calculation argument value that ValueFormatter.format_input/3 rejected:
  # the error the reason gets for an action input, under the argument's path
  # (`calc_path` is the selection path ending at the calculation, `key` the
  # argument as sent).
  defp build({:invalid_calculation_arg_value, reason, calc_path, key}, ctx)
       when is_list(calc_path) do
    prefix = selection_path(calc_path, ctx) ++ [param_name(:args, ctx.formatter), key]
    build_at(reason, prefix, ctx)
  end

  # Field selection requirement errors - accepts raw path and field_name
  defp build({:requires_field_selection, field_type, field, path}, ctx)
       when is_list(path) and is_atom(field) do
    drift(
      ctx,
      "requires_field_selection",
      "%{field_type} %{field} requires field selection",
      "Field selection required",
      field_opts(path, field, ctx, %{field_type: capitalize(field_kind(field_type))}) ++
        [
          details: %{
            suggestion: "Specify which fields to select from this #{field_kind(field_type)}"
          }
        ]
    )
  end

  # Typed values report the path to the value itself; nested ones name the
  # field (last path segment), top-level ones (empty path) have no field.
  defp build({:requires_field_selection, field_type, [_ | _] = path}, ctx) do
    {parent_path, [field]} = Enum.split(path, -1)
    build({:requires_field_selection, field_type, field, parent_path}, ctx)
  end

  defp build({:requires_field_selection, field_type, []}, ctx) do
    drift(
      ctx,
      "requires_field_selection",
      "%{field_type} requires field selection",
      "Field selection required",
      vars: %{field_type: capitalize(field_kind(field_type))},
      details: %{suggestion: "Specify which fields to select from this #{field_kind(field_type)}"}
    )
  end

  defp build({:invalid_field_selection, field, field_type, path}, ctx) when is_list(path) do
    field_type_string = format_field_type(field_type)

    drift(
      ctx,
      "invalid_field_selection",
      "Cannot select fields from %{field_type} %{field}",
      "Invalid field selection",
      field_opts(path, field, ctx, %{field_type: field_type_string}) ++
        [
          details: %{
            suggestion: "Remove the field selection for this #{field_type_string} field"
          }
        ]
    )
  end

  defp build(
         {:invalid_field_selection, :primitive_type, return_type, requested_fields, path},
         ctx
       ) do
    drift(
      ctx,
      "invalid_field_selection",
      "Cannot select fields from primitive type %{return_type}",
      "Invalid field selection",
      vars: %{return_type: format_field_type(return_type)},
      path: selection_path(path, ctx),
      details: %{
        requested_fields: requested_fields,
        suggestion: "Remove the field selection for this primitive type"
      }
    )
  end

  # A calculation selected in a value that isn't loaded through (an
  # aggregate's, a typed value field's). Not a drift hint: no generated client
  # offers this selection.
  defp build({:value_calculation_load, field_type, field, path}, ctx) when is_list(path) do
    malformed(
      "invalid_field_selection",
      "Cannot load calculations of the value of %{field_type} %{field}",
      "Invalid field selection",
      field_opts(path, field, ctx, %{field_type: format_field_type(field_type)}) ++
        [details: %{suggestion: "Select only attributes of its value"}]
    )
  end

  # Field nesting errors
  defp build({:field_does_not_support_nesting, field, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "field_does_not_support_nesting",
      "Field %{field} does not support nested field selection",
      "Field does not support nesting",
      field_opts(path, field, ctx) ++
        [details: %{suggestion: "Remove the nested specification for this field"}]
    )
  end

  # Duplicate field errors
  defp build({:duplicate_field, field, path}, ctx) when is_list(path) do
    malformed(
      "duplicate_field",
      "Field %{field} was requested multiple times",
      "Duplicate field",
      field_opts(path, field, ctx) ++
        [details: %{suggestion: "Remove duplicate field specifications"}]
    )
  end

  # Field combination errors
  defp build({:unsupported_field_combination, field_type, field, field_spec, path}, ctx)
       when is_list(path) do
    drift(
      ctx,
      "unsupported_field_combination",
      "Unsupported combination of field type and specification for %{field}",
      "Unsupported field combination",
      field_opts(path, field, ctx, %{field_type: field_kind(field_type)}) ++
        [
          details: %{
            field_spec: inspect(field_spec),
            suggestion: "Check the documentation for valid field specification formats"
          }
        ]
    )
  end

  # === FIELD VALIDATION ERRORS (WITHOUT FIELD PATHS) ===

  defp build({:invalid_fields_type, fields}, _ctx) do
    malformed("invalid_fields_type", "Fields parameter must be an array", "Invalid fields type",
      vars: %{received: inspect(fields)},
      details: %{
        expected_code: "array",
        suggestion: "Wrap field names in an array, e.g., [\"field1\", \"field2\"]"
      }
    )
  end

  # === UNION INPUT VALIDATION ERRORS ===

  defp build({:invalid_union_input, :not_a_map}, ctx) do
    drift(
      ctx,
      "invalid_union_input",
      "Union input must be a map with exactly one member key",
      "Invalid union input",
      details: %{suggestion: "Provide union input in the format: {\"member_name\": value}"}
    )
  end

  defp build({:invalid_union_input, :no_member_key, member_names}, ctx) do
    drift(
      ctx,
      "invalid_union_input",
      "Union input map does not contain any valid member key",
      "Invalid union input",
      vars: %{expected_members: Enum.join(member_names, ", ")},
      details: %{
        expected_members: member_names,
        suggestion: "Provide exactly one of the following keys: %{expected_members}"
      }
    )
  end

  defp build({:invalid_union_input, :multiple_member_keys, found_keys, member_names}, _ctx) do
    malformed(
      "invalid_union_input",
      "Union input map contains multiple member keys: %{found_keys}",
      "Invalid union input",
      vars: %{
        found_keys: Enum.join(found_keys, ", "),
        expected_members: Enum.join(member_names, ", ")
      },
      details: %{
        suggestion:
          "Provide exactly one member key, not multiple. Choose one of: %{expected_members}"
      }
    )
  end

  # === INPUT AND SYSTEM VALIDATION ERRORS ===

  # A server-side bug: the generic action's run returned a bare member value.
  defp build({:invalid_union_return, action_name}, _ctx) do
    malformed(
      "invalid_union_return",
      "Action %{action} must return an Ash.Union value, not a bare member value",
      "Invalid union return",
      vars: %{action: action_name}
    )
  end

  defp build({:missing_required_parameter, parameter}, ctx) do
    drift(
      ctx,
      "missing_required_parameter",
      "Required parameter %{parameter} is missing or empty",
      "Missing required parameter",
      vars: %{parameter: to_string(parameter)},
      details: %{suggestion: "Ensure %{parameter} parameter is provided and not empty"}
    )
  end

  # Field names are already formatted by the pipeline
  defp build({:missing_get_by_fields, missing_fields}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    drift(
      ctx,
      "missing_required_input",
      "Required #{get_by} fields are missing: %{fields}",
      "Missing required #{get_by} fields",
      vars: %{fields: Enum.join(missing_fields, ", ")},
      path: format_path([:get_by], ctx.formatter),
      fields: missing_fields,
      details: %{suggestion: "Provide values for all required #{get_by} fields"}
    )
  end

  # Field names are already formatted by the pipeline
  defp build({:unexpected_get_by_fields, extra_fields, allowed_fields}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    drift(
      ctx,
      "unexpected_get_by_fields",
      "Unexpected #{get_by} fields: %{extra_fields}. Allowed fields: %{allowed_fields}",
      "Unexpected #{get_by} fields",
      vars: %{
        extra_fields: Enum.join(extra_fields, ", "),
        allowed_fields: Enum.join(allowed_fields, ", ")
      },
      path: format_path([:get_by], ctx.formatter),
      fields: extra_fields,
      details: %{
        allowed_fields: allowed_fields,
        suggestion: "Only provide the allowed #{get_by} fields: %{allowed_fields}"
      }
    )
  end

  # Field names are the client's as sent; allowed names are client names
  defp build({:unknown_metadata_fields, unknown_fields, allowed_fields}, ctx) do
    drift(
      ctx,
      "unknown_metadata_fields",
      "Unknown metadata fields: %{fields}. Allowed fields: %{allowed_fields}",
      "Unknown metadata fields",
      vars: %{
        fields: Enum.join(unknown_fields, ", "),
        allowed_fields: Enum.join(allowed_fields, ", ")
      },
      path: format_path([:metadata_fields], ctx.formatter),
      fields: unknown_fields,
      details: %{
        allowed_fields: allowed_fields,
        suggestion: "Only request the allowed metadata fields: %{allowed_fields}"
      }
    )
  end

  defp build({:invalid_action_type, action}, ctx),
    do:
      param_type_error(ctx, :action, "invalid_action_type", "a string", action,
        expected: "The name of an RPC action"
      )

  defp build({:invalid_tenant_type, tenant}, ctx),
    do:
      param_type_error(ctx, :tenant, "invalid_tenant_type", "a string or an integer", tenant,
        expected: "A string or an integer"
      )

  defp build({:invalid_metadata_fields_type, metadata_fields}, ctx),
    do:
      param_type_error(
        ctx,
        :metadata_fields,
        "invalid_metadata_fields_type",
        "an array",
        metadata_fields,
        expected: "Array of metadata field names"
      )

  defp build({:empty_fields_array, _fields}, _ctx) do
    malformed("empty_fields_array", "Fields array cannot be empty", "Empty fields array",
      details: %{suggestion: "Provide at least one field name in the fields array"}
    )
  end

  # === LOAD RESTRICTION ERRORS ===

  defp build({:load_not_allowed, paths}, ctx) do
    disallowed_paths = Enum.map(paths, &load_path(&1, ctx))

    drift(
      ctx,
      "load_not_allowed",
      "Loading the following fields is not allowed: %{fields}",
      "Load not allowed",
      vars: %{fields: Enum.join(disallowed_paths, ", ")},
      fields: disallowed_paths,
      details: %{
        disallowed_paths: disallowed_paths,
        suggestion:
          "Remove these fields from your request or check the entrypoint's load_restrictions"
      }
    )
  end

  defp build({:load_denied, paths}, ctx) do
    denied_paths = Enum.map(paths, &load_path(&1, ctx))

    drift(
      ctx,
      "load_denied",
      "Loading the following fields is denied: %{fields}",
      "Load denied",
      vars: %{fields: Enum.join(denied_paths, ", ")},
      fields: denied_paths,
      details: %{
        denied_paths: denied_paths,
        suggestion: "Remove these fields from your request"
      }
    )
  end

  defp build({:invalid_input_format, invalid_input}, _ctx) do
    malformed("invalid_input_format", "Input parameter must be a map", "Invalid input format",
      vars: %{received: inspect(invalid_input)},
      details: %{expected: "Map containing input parameters"}
    )
  end

  # An `input` key that is not one of the action's client input names; the
  # same wire error Ash's NoSuchInput maps to (lib/ash_rpc/error.ex).
  defp build({:unknown_input, key}, ctx), do: build({:unknown_input, key, []}, ctx)

  # A nested input key that is not a client name of its type; `path` holds
  # the parent keys as sent and array indexes.
  defp build({:unknown_input, key, path}, ctx) do
    drift(ctx, "unknown_input", "Unknown input %{field}", "Unknown input",
      vars: %{field: key},
      fields: [key],
      path: Enum.map(path, &path_segment(&1, ctx.formatter))
    )
  end

  defp build({:unknown_page_keys, keys}, ctx) do
    keys = Enum.map(keys, &client_name(&1, ctx.formatter))

    malformed("invalid_pagination", "Unknown pagination keys: %{keys}", "Invalid pagination",
      vars: %{keys: Enum.join(keys, ", ")},
      path: format_path([:page], ctx.formatter),
      fields: keys,
      details: %{
        expected:
          "Offset pagination (limit, offset, count) or keyset pagination (limit, after, before)"
      }
    )
  end

  # A filter statement (the filter, a list entry, an and/or/not operand or a
  # relationship's condition) that is not a map or a list. Reported through
  # `AshRpc.FilterInput.InvalidValue`, which supplies the path.
  defp build(:invalid_filter_statement, _ctx) do
    malformed("invalid_filter", "Invalid filter statement", "Invalid filter",
      details: %{
        expected:
          "A map of field names, relationships and and/or/not to conditions, or a list of such maps"
      }
    )
  end

  # A filter operator value of the wrong shape for the operator (`in` takes a
  # list, `isNil` a boolean). Reported through `AshRpc.FilterInput.InvalidValue`,
  # which supplies the path. Ash's own `InvalidFilterValue` gets the same type.
  defp build({:invalid_filter_value, expected}, _ctx) do
    malformed("invalid_filter_value", "Invalid filter value", "Invalid filter value",
      details: %{expected: expected}
    )
  end

  # A calculation argument in a filter that is missing or that its type
  # rejects (`problem` `:required` / `:invalid`), `arg` its client name.
  # Reported through `AshRpc.FilterInput.InvalidValue`, which supplies the path
  # (the calculation's `input`). Same shape as the `AshRpc.Error` impl for
  # `Ash.Error.Query.InvalidCalculationArgument`, so no `details`.
  defp build({:invalid_calculation_argument, arg, problem}, _ctx) do
    %{
      type: "invalid_calculation_argument",
      message: if(problem == :required, do: "is required", else: "is invalid"),
      short_message: "Invalid calculation argument",
      vars: %{field: arg},
      fields: [arg],
      path: []
    }
  end

  # A calculation `input` in a filter that is not a map. Reported through
  # `AshRpc.FilterInput.InvalidValue`, which supplies the path.
  defp build(:invalid_calculation_input, _ctx) do
    malformed(
      "invalid_calculation_args",
      "Calculation input must be a map",
      "Invalid calculation arguments",
      details: %{expected: "Map of argument names to values"}
    )
  end

  defp build({:invalid_pagination, invalid_value}, _ctx) do
    malformed(
      "invalid_pagination",
      "Invalid pagination parameter format",
      "Invalid pagination",
      vars: %{received: inspect(invalid_value)},
      details: %{expected: "Map with pagination parameters (limit, offset, before, after, etc.)"}
    )
  end

  # === IDENTITY VALIDATION ERRORS ===

  # Keys are already formatted for client display by the pipeline
  defp build(
         {:invalid_identity, %{provided_keys: provided_keys, expected_keys: expected_keys}},
         ctx
       ) do
    expected_keys_str = Enum.join(expected_keys, ", ")

    drift(
      ctx,
      "invalid_identity",
      "Identity fields do not match any configured identity. Provided: [%{provided_keys}], expected: [%{expected_keys}]",
      "Invalid identity",
      vars: %{provided_keys: Enum.join(provided_keys, ", "), expected_keys: expected_keys_str},
      path: format_path([:identity], ctx.formatter),
      details: %{
        provided_keys: provided_keys,
        expected_keys: expected_keys,
        suggestion:
          "Provide all required fields for one of the configured identities: #{expected_keys_str}"
      }
    )
  end

  # A scalar identity for a composite primary key; `keys` are the key's client
  # names.
  defp build({:invalid_identity, %{composite_primary_key: keys}}, ctx) do
    keys_str = Enum.join(keys, ", ")

    drift(
      ctx,
      "invalid_identity",
      "Identity must be a map of the primary key fields for a composite primary key: [%{expected_keys}]",
      "Invalid identity",
      vars: %{expected_keys: keys_str},
      path: format_path([:identity], ctx.formatter),
      details: %{
        expected_keys: keys,
        suggestion: "Provide the identity as a map of #{keys_str}"
      }
    )
  end

  # Identity / getBy values that are not scalar equality operands; `keys` are
  # client names.
  defp build({:invalid_identity, %{non_scalar_keys: keys}}, ctx) do
    malformed(
      "invalid_identity",
      "Identity values must be scalar equality operands. Non-scalar value provided for: %{fields}",
      "Invalid identity",
      vars: %{fields: Enum.join(keys, ", ")},
      fields: keys,
      path: format_path([:identity], ctx.formatter),
      details: %{suggestion: "Provide a scalar value for each identity field"}
    )
  end

  defp build({:invalid_get_by, %{non_scalar_keys: keys}}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    malformed(
      "invalid_get_by",
      "#{get_by} values must be scalar equality operands. Non-scalar value provided for: %{fields}",
      "Invalid #{get_by} value",
      vars: %{fields: Enum.join(keys, ", ")},
      fields: keys,
      path: format_path([:get_by], ctx.formatter),
      details: %{suggestion: "Provide a scalar value for each #{get_by} field"}
    )
  end

  defp build({:invalid_identity, %{message: message}}, ctx) do
    malformed("invalid_identity", message, "Invalid identity",
      path: format_path([:identity], ctx.formatter),
      details: %{suggestion: "Check the configured identities for this action"}
    )
  end

  defp build({:invalid_get_by, %{message: message}}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    malformed("invalid_get_by", message, "Invalid #{get_by} value",
      path: format_path([:get_by], ctx.formatter),
      details: %{suggestion: "Provide a scalar value for each #{get_by} field"}
    )
  end

  defp build({:invalid_get_by_format, get_by_value}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    param_type_error(ctx, :get_by, "invalid_get_by", "a map", get_by_value,
      expected: "Map of #{get_by} field names to values",
      short_message: "Invalid #{get_by} value"
    )
  end

  defp build({:missing_identity, %{expected_keys: expected_keys, identities: identities}}, ctx) do
    identity = param_name(:identity, ctx.formatter)
    expected_keys_str = Enum.join(expected_keys, ", ")

    # Check if the only identity is _primary_key with a single field
    # In this case, provide a simpler, clearer message
    {message, suggestion} =
      case {identities, expected_keys} do
        {[:_primary_key], [single_key]} ->
          {"Identity is required. Provide the #{single_key} value directly.",
           "Pass the #{single_key} value directly as the #{identity} field (e.g., #{identity}: \"your-#{single_key}-here\")"}

        _ ->
          {"Identity is required but not provided. Expected one of: [%{expected_keys}]",
           "Provide identity fields for one of the configured identities: #{expected_keys_str}"}
      end

    drift(ctx, "missing_identity", message, "Missing identity",
      vars: %{expected_keys: expected_keys_str},
      path: format_path([:identity], ctx.formatter),
      details: %{expected_keys: expected_keys, suggestion: suggestion}
    )
  end

  # === NESTED RELATIONSHIP QUERY OPTION ERRORS ===

  defp build({:query_opts_on_non_relationship, field, kind, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "invalid_query_opts",
      "Field %{field} is a %{kind} and does not accept query options (page/filter/sort/limit/offset)",
      "Invalid query options",
      field_opts(path, field, ctx, %{kind: to_string(kind)}) ++
        [
          details: %{
            suggestion:
              "Query options are only supported on has_many and many_to_many relationships"
          }
        ]
    )
  end

  defp build({:query_opts_on_to_one, field, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "invalid_query_opts",
      "Relationship %{field} is to-one and does not accept query options",
      "Invalid query options",
      field_opts(path, field, ctx) ++
        [details: %{suggestion: "Use a plain nested field list for to-one relationships"}]
    )
  end

  defp build({:args_and_query_opts_combined, field, path}, ctx) when is_list(path) do
    malformed(
      "invalid_query_opts",
      "Field %{field} combines args with query options; they are mutually exclusive",
      "Invalid query options",
      field_opts(path, field, ctx) ++
        [details: %{suggestion: "Remove the args key — relationships do not take arguments"}]
    )
  end

  defp build({:page_and_limit_offset_combined, field, path}, ctx) when is_list(path) do
    malformed(
      "invalid_query_opts",
      "Field %{field} combines page with bare limit/offset; use one or the other",
      "Invalid query options",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion: "Use page for paginated results or bare limit/offset for a plain slice"
          }
        ]
    )
  end

  # Keys in a relationship envelope that are not envelope options, as sent;
  # `path` ends at the relationship.
  defp build({:unknown_query_opts, field, keys, path}, ctx) when is_list(path) do
    keys = Enum.map(keys, &client_name(&1, ctx.formatter))

    expected =
      [:fields, :page, :filter, :sort, :limit, :offset]
      |> Enum.map_join(", ", &param_name(&1, ctx.formatter))

    malformed(
      "invalid_query_opts",
      "Unknown query option keys for relationship %{field}: %{keys}",
      "Invalid query options",
      path
      |> field_opts(field, ctx, %{keys: Enum.join(keys, ", ")})
      |> Keyword.put(:path, selection_path(path ++ [field], ctx))
      |> Keyword.put(:details, %{expected: expected})
    )
  end

  # A bare `limit` / `offset` in a relationship envelope that is not a
  # non-negative integer; `path` ends at the key.
  defp build({:invalid_query_opt_value, field, key, path}, ctx) when is_list(path) do
    key = client_name(key, ctx.formatter)

    malformed(
      "invalid_query_opts",
      "%{key} for relationship %{field} must be a non-negative integer",
      "Invalid query options",
      path
      |> field_opts(field, ctx, %{key: key})
      |> Keyword.put(:path, selection_path(path ++ [field], ctx) ++ [key])
      |> Keyword.put(:details, %{expected: "A non-negative integer"})
    )
  end

  defp build({:nested_pagination_not_supported, field, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "pagination_not_supported",
      "Relationship %{field} does not support pagination",
      "Pagination not supported",
      field_opts(path, field, ctx) ++
        [
          details: %{
            reason: "unsupported",
            suggestion:
              "The relationship's read action has no pagination configured. Use bare limit/offset, or add pagination to the destination read action"
          }
        ]
    )
  end

  defp build({:get_by_not_supported, :top_level, reason}, ctx) do
    get_by = param_name(:get_by, ctx.formatter)

    drift(
      ctx,
      "get_by_not_supported",
      "This action does not support the #{get_by} parameter",
      "#{get_by} not supported",
      path: format_path([:get_by], ctx.formatter),
      details: %{
        reason: to_string(reason),
        suggestion:
          "Remove the #{get_by} parameter. It is only available on entrypoints that declare get_by fields"
      }
    )
  end

  defp build({:filter_not_supported, :top_level, reason}, ctx) do
    drift(
      ctx,
      "filter_not_supported",
      "This action does not support the filter parameter",
      "Filter not supported",
      details: %{
        reason: to_string(reason),
        suggestion:
          "Remove the filter parameter. It is unavailable because the action is not a list read (get?/non-read) or filtering is disabled via enable_filter?: false"
      }
    )
  end

  defp build({:filter_not_supported, field, reason, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "filter_not_supported",
      "Relationship %{field} does not support filtering",
      "Filter not supported",
      field_opts(path, field, ctx) ++
        [
          details: %{
            reason: to_string(reason),
            suggestion:
              "Remove the filter key. Filtering is unavailable because the entrypoint disables it (enable_filter?: false) or the relationship is not filterable?"
          }
        ]
    )
  end

  defp build({:sort_not_supported, :top_level, reason}, ctx) do
    drift(
      ctx,
      "sort_not_supported",
      "This action does not support the sort parameter",
      "Sort not supported",
      details: %{
        reason: to_string(reason),
        suggestion:
          "Remove the sort parameter. It is unavailable because the action is not a list read (get?/non-read) or sorting is disabled via enable_sort?: false"
      }
    )
  end

  defp build({:sort_not_supported, field, reason, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "sort_not_supported",
      "Relationship %{field} does not support sorting",
      "Sort not supported",
      field_opts(path, field, ctx) ++
        [
          details: %{
            reason: to_string(reason),
            suggestion:
              "Remove the sort key. Sorting is unavailable because the entrypoint disables it (enable_sort?: false) or the relationship is not sortable?"
          }
        ]
    )
  end

  defp build({:pagination_not_supported, :top_level, reason}, ctx) do
    drift(
      ctx,
      "pagination_not_supported",
      "This action does not support the page parameter",
      "Pagination not supported",
      details: %{
        reason: to_string(reason),
        suggestion:
          "Remove the page parameter. It is unavailable because the action is not a list read (get?/non-read) or has no pagination configured"
      }
    )
  end

  defp build({:invalid_nested_page, field, reason, path}, ctx) when is_list(path) do
    {reason, extra_vars} =
      case reason do
        {:unknown_keys, keys} ->
          keys = Enum.map(keys, &client_name(&1, ctx.formatter))
          {"unknown_keys", %{keys: Enum.join(keys, ", ")}}

        reason ->
          {to_string(reason), %{}}
      end

    drift(
      ctx,
      "invalid_pagination",
      "Invalid page configuration for relationship %{field}",
      "Invalid pagination",
      field_opts(path, field, ctx, extra_vars) ++
        [
          details: %{
            reason: reason,
            suggestion:
              "Provide page keys valid for the relationship's pagination type (offset: limit/offset/count, keyset: limit/after/before/count)"
          }
        ]
    )
  end

  # === FIELD TYPE ERRORS ===

  # Invalid field type errors (from validator throws)
  defp build({:invalid_field_type, field, path}, ctx) do
    drift(
      ctx,
      "unknown_field",
      "Unknown field %{field}",
      "Unknown field",
      field_opts(path, field, ctx) ++
        [details: %{suggestion: "Check that the field exists and is accessible"}]
    )
  end

  # === LISTS, REACTOR AND ASH ERRORS ===

  # e.g. the errors of an Ash.BulkResult
  defp build(errors, ctx) when is_list(errors) do
    Enum.flat_map(errors, &(ctx.runtime |> build_error_response(&1, ctx.scope) |> List.wrap()))
  end

  # A step may fail with any term; converting first keeps it out of the tuple clauses above
  defp build(%Reactor.Error.Invalid.RunStepError{error: inner_error}, ctx) do
    build_error_response(ctx.runtime, Ash.Error.to_error_class(inner_error), ctx.scope)
  end

  # Any exception or Ash error; Errors.to_errors/6 converts it to an Ash error class
  defp build(error, ctx) when is_exception(error) or is_map(error) do
    scope = ctx.scope || %{}

    Errors.to_errors(
      ctx.runtime,
      error,
      scope[:domain],
      scope[:resource],
      scope[:action],
      scope[:context] || %{}
    )
  end

  # Anything else is an internal term: logged server-side, the client gets only an error id.
  defp build(other, _ctx), do: Errors.unhandled_error(other)

  defp action_not_found_suggestion(%{profile: nil}),
    do: AshRpc.Profile.default_action_not_found_suggestion()

  defp action_not_found_suggestion(%{profile: profile}), do: profile.action_not_found_suggestion()

  defp suggestion_details(nil), do: %{}
  defp suggestion_details(suggestion), do: %{suggestion: suggestion}

  defp drop_nil_hint(%{details: %{hint: nil} = details} = error),
    do: %{error | details: Map.delete(details, :hint)}

  defp drop_nil_hint(error), do: error

  defp format_field_type(%Ash.Info.Manifest.Type{name: name}) when is_binary(name), do: name
  defp format_field_type(other) when is_atom(other) or is_binary(other), do: field_kind(other)
  defp format_field_type(_), do: "unknown"

  # The kind of field, in client wording, for a field selector category.
  defp field_kind(:primitive_type), do: "primitive type"
  defp field_kind(:embedded_resource), do: "embedded resource"
  defp field_kind(kind) when kind in [:union, :union_attribute], do: "union"
  defp field_kind(:field_constrained_type), do: "typed value"

  defp field_kind(kind)
       when kind in [:calculation, :calculation_complex, :calculation_with_args],
       do: "calculation"

  defp field_kind(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp field_kind(kind), do: to_string(kind)

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
  defp capitalize(other), do: other

  # Fixed-vocabulary paths (`getBy`, `identity`, `metadataFields`, `page`).
  defp format_path(path, formatter) when is_list(path) do
    Enum.map(path, &param_name(&1, formatter))
  end

  # A request param's client name, for paths and for message text naming it.
  defp param_name(name, formatter),
    do: FieldFormatter.format_field_name(to_string(name), formatter)

  # A string name is a client name that missed, so it is reported as sent;
  # an atom is an internal name and is formatted.
  defp client_name(name, _formatter) when is_binary(name), do: name
  defp client_name(name, formatter), do: FieldFormatter.format_field_name(name, formatter)

  defp path_segment(index, _formatter) when is_integer(index), do: index
  defp path_segment(name, formatter), do: client_name(name, formatter)
end
