# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorBuilder do
  @moduledoc """
  Comprehensive error handling and message generation for the RPC pipeline.

  Provides clear, actionable error messages for all failure modes with
  detailed context for debugging and client consumption.
  """

  alias AshRpc.{Errors, FieldFormatter}

  @doc """
  Builds a detailed error response from various error types.

  Converts internal error tuples into structured error responses
  with clear messages and debugging context.

  For Ash framework errors, uses the new Error protocol for standardized extraction.

  Returns either a single error map or a list of error maps (for Ash errors with multiple sub-errors).

  `scope` is `nil` or `%{domain:, resource:, action:, context:}`; Ash errors are
  routed through `AshRpc.Errors.to_errors/6` with it, so the profile's domain
  error handling applies to execution errors too.
  """
  @spec build_error_response(AshRpc.Runtime.t(), term(), map() | nil) :: map() | list(map())
  def build_error_response(runtime, error, scope \\ nil) do
    ctx = %{
      runtime: runtime,
      scope: scope,
      formatter: runtime.output_formatter,
      hint: stale_client_hint(runtime)
    }

    error |> build(ctx) |> drop_nil_hint()
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
  defp field_opts(path, field, ctx, extra_vars \\ %{}) do
    full_field_path = build_complete_field_path(path, field, ctx.formatter)

    [
      vars: Map.put(extra_vars, :field, full_field_path),
      path: format_path(path, ctx.formatter),
      fields: [full_field_path]
    ]
  end

  # Action discovery errors
  defp build({:action_not_found, action_name}, ctx) do
    drift(ctx, "action_not_found", "RPC action %{action_name} not found", "Action not found",
      vars: %{action_name: action_name},
      details: %{
        suggestion: "Check that the action is properly configured in your domain's rpc block"
      }
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

  defp build({:unknown_field, field, resource, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "unknown_field",
      "Unknown field %{field} for resource %{resource}",
      "Unknown field",
      field_opts(path, field, ctx, %{resource: inspect(resource)}) ++
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
    drift(
      ctx,
      "invalid_field_format",
      "Calculation %{field} requires arguments",
      "Calculation requires arguments",
      field_opts(path, field, ctx) ++
        [
          details: %{
            suggestion: "Provide arguments in the format: {\"#{field}\": {\"args\": {...}}}"
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
      path: format_path(path, ctx.formatter),
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

  # Field selection requirement errors - accepts raw path and field_name
  defp build({:requires_field_selection, field_type, field, path}, ctx)
       when is_list(path) and is_atom(field) do
    drift(
      ctx,
      "requires_field_selection",
      "%{field_type} %{field} requires field selection",
      "Field selection required",
      field_opts(path, field, ctx, %{field_type: String.capitalize(to_string(field_type))}) ++
        [details: %{suggestion: "Specify which fields to select from this #{field_type}"}]
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
      vars: %{field_type: String.capitalize(to_string(field_type))},
      details: %{suggestion: "Specify which fields to select from this #{field_type}"}
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
      path: format_path(path, ctx.formatter),
      details: %{
        requested_fields: requested_fields,
        suggestion: "Remove the field selection for this primitive type"
      }
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
      field_opts(path, field, ctx, %{field_type: to_string(field_type)}) ++
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
    drift(
      ctx,
      "missing_required_input",
      "Required getBy fields are missing: %{fields}",
      "Missing required getBy fields",
      vars: %{fields: Enum.join(missing_fields, ", ")},
      path: [:get_by],
      fields: missing_fields,
      details: %{suggestion: "Provide values for all required getBy fields"}
    )
  end

  # Field names are already formatted by the pipeline
  defp build({:unexpected_get_by_fields, extra_fields, allowed_fields}, ctx) do
    drift(
      ctx,
      "unexpected_get_by_fields",
      "Unexpected getBy fields: %{extra_fields}. Allowed fields: %{allowed_fields}",
      "Unexpected getBy fields",
      vars: %{
        extra_fields: Enum.join(extra_fields, ", "),
        allowed_fields: Enum.join(allowed_fields, ", ")
      },
      path: [:get_by],
      fields: extra_fields,
      details: %{
        allowed_fields: allowed_fields,
        suggestion: "Only provide the allowed getBy fields: %{allowed_fields}"
      }
    )
  end

  defp build({:empty_fields_array, _fields}, _ctx) do
    malformed("empty_fields_array", "Fields array cannot be empty", "Empty fields array",
      details: %{suggestion: "Provide at least one field name in the fields array"}
    )
  end

  # === LOAD RESTRICTION ERRORS ===

  defp build({:load_not_allowed, disallowed_paths}, ctx) do
    drift(
      ctx,
      "load_not_allowed",
      "Loading the following fields is not allowed: %{fields}",
      "Load not allowed",
      vars: %{fields: Enum.join(disallowed_paths, ", ")},
      fields: disallowed_paths,
      details: %{
        disallowed_paths: disallowed_paths,
        suggestion: "Remove these fields from your request or check allowed_loads configuration"
      }
    )
  end

  defp build({:load_denied, denied_paths}, ctx) do
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

  defp build({:unknown_page_keys, keys}, ctx) do
    keys = Enum.map(keys, &FieldFormatter.format_field_name(&1, ctx.formatter))

    malformed("invalid_pagination", "Unknown pagination keys: %{keys}", "Invalid pagination",
      vars: %{keys: Enum.join(keys, ", ")},
      path: ["page"],
      fields: keys,
      details: %{
        expected:
          "Offset pagination (limit, offset, count) or keyset pagination (limit, after, before)"
      }
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
      path: [:identity],
      details: %{
        provided_keys: provided_keys,
        expected_keys: expected_keys,
        suggestion:
          "Provide all required fields for one of the configured identities: #{expected_keys_str}"
      }
    )
  end

  defp build({:invalid_identity, %{message: message}}, _ctx) do
    malformed("invalid_identity", message, "Invalid identity",
      path: [:identity],
      details: %{suggestion: "Check the configured identities for this action"}
    )
  end

  defp build({:invalid_get_by, %{message: message}}, _ctx) do
    malformed("invalid_get_by", message, "Invalid getBy value",
      path: [:get_by],
      details: %{suggestion: "Provide a scalar value for each getBy field"}
    )
  end

  defp build({:missing_identity, %{expected_keys: expected_keys, identities: identities}}, ctx) do
    expected_keys_str = Enum.join(expected_keys, ", ")

    # Check if the only identity is _primary_key with a single field
    # In this case, provide a simpler, clearer message
    {message, suggestion} =
      case {identities, expected_keys} do
        {[:_primary_key], [single_key]} ->
          {"Identity is required. Provide the #{single_key} value directly.",
           "Pass the #{single_key} value directly as the identity field (e.g., identity: \"your-#{single_key}-here\")"}

        _ ->
          {"Identity is required but not provided. Expected one of: [%{expected_keys}]",
           "Provide identity fields for one of the configured identities: #{expected_keys_str}"}
      end

    drift(ctx, "missing_identity", message, "Missing identity",
      vars: %{expected_keys: expected_keys_str},
      path: [:identity],
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

  defp build({:nested_pagination_not_supported, field, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "pagination_not_supported",
      "Relationship %{field} does not support pagination",
      "Pagination not supported",
      field_opts(path, field, ctx) ++
        [
          details: %{
            reason: :unsupported,
            suggestion:
              "The relationship's read action has no pagination configured. Use bare limit/offset, or add pagination to the destination read action"
          }
        ]
    )
  end

  defp build({:filter_not_supported, :top_level, reason}, ctx) do
    drift(
      ctx,
      "filter_not_supported",
      "This action does not support the filter parameter",
      "Filter not supported",
      details: %{
        reason: reason,
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
            reason: reason,
            suggestion:
              "Remove the filter key. Filtering is unavailable because the RPC action disables it (enable_filter?: false) or the relationship is not filterable?"
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
        reason: reason,
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
            reason: reason,
            suggestion:
              "Remove the sort key. Sorting is unavailable because the RPC action disables it (enable_sort?: false) or the relationship is not sortable?"
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
        reason: reason,
        suggestion:
          "Remove the page parameter. It is unavailable because the action is not a list read (get?/non-read) or has no pagination configured"
      }
    )
  end

  defp build({:invalid_nested_page, field, reason, path}, ctx) when is_list(path) do
    drift(
      ctx,
      "invalid_pagination",
      "Invalid page configuration for relationship %{field}",
      "Invalid pagination",
      field_opts(path, field, ctx) ++
        [
          details: %{
            reason: inspect(reason),
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

  defp build({field_error_type, _} = error, ctx) when is_atom(field_error_type) do
    drift(
      ctx,
      "field_validation_error",
      "Field validation error: %{error_type}",
      "Field validation error",
      vars: %{error_type: to_string(field_error_type)},
      details: %{error: inspect(error)}
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

  defp build(other, _ctx) do
    malformed("unknown_error", "An unexpected error occurred", "Unknown error",
      details: %{error: inspect(other)}
    )
  end

  defp stale_client_hint(%{profile: nil}), do: AshRpc.Profile.default_stale_client_hint()
  defp stale_client_hint(%{profile: profile}), do: profile.stale_client_hint()

  defp drop_nil_hint(%{details: %{hint: nil} = details} = error),
    do: %{error | details: Map.delete(details, :hint)}

  defp drop_nil_hint(error), do: error

  defp format_field_type(:primitive_type), do: "primitive type"
  defp format_field_type(%Ash.Info.Manifest.Type{name: name}) when is_binary(name), do: name
  defp format_field_type({:ash_type, type, _}), do: inspect(type)
  defp format_field_type(other), do: inspect(other)

  defp format_path(path, formatter) when is_list(path) do
    Enum.map(path, &FieldFormatter.format_field_name(to_string(&1), formatter))
  end

  defp build_complete_field_path(path, field_name, formatter) when is_list(path) do
    formatted_field = FieldFormatter.format_field_name(to_string(field_name), formatter)

    case format_path(path, formatter) do
      [] -> formatted_field
      formatted_path -> Enum.join(formatted_path ++ [formatted_field], ".")
    end
  end
end
