# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorBuilder do
  @moduledoc """
  Comprehensive error handling and message generation for the RPC pipeline.

  Provides clear, actionable error messages for all failure modes with
  detailed context for debugging and client consumption.
  """

  alias AshRpc.Errors

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
    formatter = runtime.output_formatter
    hint = stale_client_hint(runtime)

    error
    |> build(runtime, scope, formatter, hint)
    |> drop_nil_hint()
  end

  defp build(error, runtime, scope, formatter, hint) do
    case error do
      # Action discovery errors
      {:action_not_found, action_name} ->
        %{
          type: "action_not_found",
          message: "RPC action %{action_name} not found",
          short_message: "Action not found",
          vars: %{action_name: action_name},
          path: [],
          fields: [],
          details: %{
            suggestion: "Check that the action is properly configured in your domain's rpc block",
            hint: hint
          }
        }

      # === FIELD VALIDATION ERRORS WITH FIELD PATHS ===

      # Unknown field errors
      {:unknown_field, field_atom, "map", path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "unknown_map_field",
          message: "Unknown field %{field} for map return type",
          short_message: "Unknown map field",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Check that the field name is valid for the map's field constraints",
            hint: hint
          }
        }

      {:unknown_field, field_atom, "union_attribute", path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "unknown_union_field",
          message: "Unknown union member %{field}",
          short_message: "Unknown union member",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion:
              "Check that the union member name is valid for the union attribute definition",
            hint: hint
          }
        }

      {:unknown_field, field_atom, kind, path} when is_binary(kind) and is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)

        %{
          type: "unknown_field",
          message: "Unknown field %{field} for %{kind} type",
          short_message: "Unknown field",
          vars: %{
            field: full_field_path,
            kind: kind |> String.trim_trailing("_type") |> String.replace("_", " ")
          },
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            suggestion: "Check that the field name is valid for the type's field constraints",
            hint: hint
          }
        }

      {:unknown_field, field_atom, resource, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "unknown_field",
          message: "Unknown field %{field} for resource %{resource}",
          short_message: "Unknown field",
          vars: %{field: full_field_path, resource: inspect(resource)},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion:
              "Check the field name spelling and ensure it's a public attribute, calculation, or relationship",
            hint: hint
          }
        }

      # Calculation errors
      {:calculation_requires_args, field_atom, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "invalid_field_format",
          message: "Calculation %{field} requires arguments",
          short_message: "Calculation requires arguments",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Provide arguments in the format: {\"#{field_atom}\": {\"args\": {...}}}",
            hint: hint
          }
        }

      # Invalid field specification format (e.g. calculation args where they are not supported)
      {:invalid_field_format, field_spec, path} when is_list(path) ->
        formatted_path = format_path(path, formatter)

        %{
          type: "invalid_field_format",
          message: "Invalid field specification format",
          short_message: "Invalid field format",
          vars: %{},
          path: formatted_path,
          fields: [],
          details: %{
            field_spec: inspect(field_spec),
            suggestion: "Check the documentation for valid field specification formats",
            hint: hint
          }
        }

      {:invalid_calculation_args, field_atom, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "invalid_calculation_args",
          message: "Invalid arguments for calculation %{field}",
          short_message: "Invalid calculation arguments",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            expected: "Map containing argument values or valid field selection format",
            hint: hint
          }
        }

      # Field selection requirement errors - accepts raw path and field_name
      {:requires_field_selection, field_type, field_name, path}
      when is_list(path) and is_atom(field_name) ->
        full_field_path = build_complete_field_path(path, field_name, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "requires_field_selection",
          message: "%{field_type} %{field} requires field selection",
          short_message: "Field selection required",
          vars: %{
            field_type: String.capitalize(to_string(field_type)),
            field: full_field_path
          },
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Specify which fields to select from this #{field_type}",
            hint: hint
          }
        }

      # Thrown without a path for top-level field-constrained types
      {:requires_field_selection, field_type, nil} ->
        %{
          type: "requires_field_selection",
          message: "%{field_type} requires field selection",
          short_message: "Field selection required",
          vars: %{
            field_type: String.capitalize(to_string(field_type))
          },
          path: [],
          fields: [],
          details: %{
            suggestion: "Specify which fields to select from this #{field_type}",
            hint: hint
          }
        }

      {:invalid_field_selection, field_atom, field_type, path} when is_list(path) ->
        field_type_string = format_field_type(field_type)
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "invalid_field_selection",
          message: "Cannot select fields from %{field_type} %{field}",
          short_message: "Invalid field selection",
          vars: %{field_type: field_type_string, field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Remove the field selection for this #{field_type_string} field",
            hint: hint
          }
        }

      {:invalid_field_selection, :primitive_type, return_type, requested_fields, path} ->
        return_type_string = format_field_type(return_type)

        %{
          type: "invalid_field_selection",
          message: "Cannot select fields from primitive type %{return_type}",
          short_message: "Invalid field selection",
          vars: %{return_type: return_type_string},
          path: format_path(path, formatter),
          fields: [],
          details: %{
            requested_fields: requested_fields,
            suggestion: "Remove the field selection for this primitive type",
            hint: hint
          }
        }

      # Field nesting errors
      {:field_does_not_support_nesting, field_name, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_name, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "field_does_not_support_nesting",
          message: "Field %{field} does not support nested field selection",
          short_message: "Field does not support nesting",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Remove the nested specification for this field",
            hint: hint
          }
        }

      # Duplicate field errors
      {:duplicate_field, field_atom, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "duplicate_field",
          message: "Field %{field} was requested multiple times",
          short_message: "Duplicate field",
          vars: %{field: full_field_path},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            suggestion: "Remove duplicate field specifications"
          }
        }

      # Field combination errors
      {:unsupported_field_combination, field_type, field_atom, field_spec, path}
      when is_list(path) ->
        full_field_path = build_complete_field_path(path, field_atom, formatter)
        formatted_path = format_path(path, formatter)

        %{
          type: "unsupported_field_combination",
          message: "Unsupported combination of field type and specification for %{field}",
          short_message: "Unsupported field combination",
          vars: %{field: full_field_path, field_type: to_string(field_type)},
          path: formatted_path,
          fields: [full_field_path],
          details: %{
            field_spec: inspect(field_spec),
            suggestion: "Check the documentation for valid field specification formats",
            hint: hint
          }
        }

      # === FIELD VALIDATION ERRORS (WITHOUT FIELD PATHS) ===

      {:invalid_fields_type, fields} ->
        %{
          type: "invalid_fields_type",
          message: "Fields parameter must be an array",
          short_message: "Invalid fields type",
          vars: %{received: inspect(fields)},
          path: [],
          fields: [],
          details: %{
            expected_code: "array",
            suggestion: "Wrap field names in an array, e.g., [\"field1\", \"field2\"]"
          }
        }

      # === UNION INPUT VALIDATION ERRORS ===

      {:invalid_union_input, :not_a_map} ->
        %{
          type: "invalid_union_input",
          message: "Union input must be a map with exactly one member key",
          short_message: "Invalid union input",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            suggestion: "Provide union input in the format: {\"member_name\": value}",
            hint: hint
          }
        }

      {:invalid_union_input, :no_member_key, member_names} ->
        %{
          type: "invalid_union_input",
          message: "Union input map does not contain any valid member key",
          short_message: "Invalid union input",
          vars: %{expected_members: Enum.join(member_names, ", ")},
          path: [],
          fields: [],
          details: %{
            expected_members: member_names,
            suggestion: "Provide exactly one of the following keys: %{expected_members}",
            hint: hint
          }
        }

      {:invalid_union_input, :multiple_member_keys, found_keys, member_names} ->
        %{
          type: "invalid_union_input",
          message: "Union input map contains multiple member keys: %{found_keys}",
          short_message: "Invalid union input",
          vars: %{
            found_keys: Enum.join(found_keys, ", "),
            expected_members: Enum.join(member_names, ", ")
          },
          path: [],
          fields: [],
          details: %{
            suggestion:
              "Provide exactly one member key, not multiple. Choose one of: %{expected_members}"
          }
        }

      # === INPUT AND SYSTEM VALIDATION ERRORS ===

      {:missing_required_parameter, parameter} ->
        %{
          type: "missing_required_parameter",
          message: "Required parameter %{parameter} is missing or empty",
          short_message: "Missing required parameter",
          vars: %{parameter: to_string(parameter)},
          path: [],
          fields: [],
          details: %{
            suggestion: "Ensure %{parameter} parameter is provided and not empty",
            hint: hint
          }
        }

      {:missing_get_by_fields, missing_fields} ->
        # Field names are already formatted by the pipeline
        field_names = Enum.join(missing_fields, ", ")

        %{
          type: "missing_required_input",
          message: "Required getBy fields are missing: %{fields}",
          short_message: "Missing required getBy fields",
          vars: %{fields: field_names},
          path: [:get_by],
          fields: missing_fields,
          details: %{
            suggestion: "Provide values for all required getBy fields",
            hint: hint
          }
        }

      {:unexpected_get_by_fields, extra_fields, allowed_fields} ->
        # Field names are already formatted by the pipeline
        extra_field_names = Enum.join(extra_fields, ", ")
        allowed_field_names = Enum.join(allowed_fields, ", ")

        %{
          type: "unexpected_get_by_fields",
          message: "Unexpected getBy fields: %{extra_fields}. Allowed fields: %{allowed_fields}",
          short_message: "Unexpected getBy fields",
          vars: %{extra_fields: extra_field_names, allowed_fields: allowed_field_names},
          path: [:get_by],
          fields: extra_fields,
          details: %{
            allowed_fields: allowed_fields,
            suggestion: "Only provide the allowed getBy fields: %{allowed_fields}",
            hint: hint
          }
        }

      {:empty_fields_array, _fields} ->
        %{
          type: "empty_fields_array",
          message: "Fields array cannot be empty",
          short_message: "Empty fields array",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            suggestion: "Provide at least one field name in the fields array"
          }
        }

      # === LOAD RESTRICTION ERRORS ===

      {:load_not_allowed, disallowed_paths} ->
        paths_str = Enum.join(disallowed_paths, ", ")

        %{
          type: "load_not_allowed",
          message: "Loading the following fields is not allowed: %{fields}",
          short_message: "Load not allowed",
          vars: %{fields: paths_str},
          path: [],
          fields: disallowed_paths,
          details: %{
            disallowed_paths: disallowed_paths,
            suggestion:
              "Remove these fields from your request or check allowed_loads configuration",
            hint: hint
          }
        }

      {:load_denied, denied_paths} ->
        paths_str = Enum.join(denied_paths, ", ")

        %{
          type: "load_denied",
          message: "Loading the following fields is denied: %{fields}",
          short_message: "Load denied",
          vars: %{fields: paths_str},
          path: [],
          fields: denied_paths,
          details: %{
            denied_paths: denied_paths,
            suggestion: "Remove these fields from your request",
            hint: hint
          }
        }

      {:invalid_input_format, invalid_input} ->
        %{
          type: "invalid_input_format",
          message: "Input parameter must be a map",
          short_message: "Invalid input format",
          vars: %{received: inspect(invalid_input)},
          path: [],
          fields: [],
          details: %{
            expected: "Map containing input parameters"
          }
        }

      {:unknown_page_keys, keys} ->
        keys =
          Enum.map(
            keys,
            &AshRpc.FieldFormatter.format_field_name(
              &1,
              formatter
            )
          )

        %{
          type: "invalid_pagination",
          message: "Unknown pagination keys: %{keys}",
          short_message: "Invalid pagination",
          vars: %{keys: Enum.join(keys, ", ")},
          path: ["page"],
          fields: keys,
          details: %{
            expected:
              "Offset pagination (limit, offset, count) or keyset pagination (limit, after, before)"
          }
        }

      {:invalid_pagination, invalid_value} ->
        %{
          type: "invalid_pagination",
          message: "Invalid pagination parameter format",
          short_message: "Invalid pagination",
          vars: %{received: inspect(invalid_value)},
          path: [],
          fields: [],
          details: %{
            expected: "Map with pagination parameters (limit, offset, before, after, etc.)"
          }
        }

      # === IDENTITY VALIDATION ERRORS ===

      {:invalid_identity, %{provided_keys: provided_keys, expected_keys: expected_keys}} ->
        # Keys are already formatted for client display by the pipeline
        provided_keys_str = Enum.join(provided_keys, ", ")
        expected_keys_str = Enum.join(expected_keys, ", ")

        %{
          type: "invalid_identity",
          message:
            "Identity fields do not match any configured identity. Provided: [%{provided_keys}], expected: [%{expected_keys}]",
          short_message: "Invalid identity",
          vars: %{provided_keys: provided_keys_str, expected_keys: expected_keys_str},
          path: [:identity],
          fields: [],
          details: %{
            provided_keys: provided_keys,
            expected_keys: expected_keys,
            suggestion:
              "Provide all required fields for one of the configured identities: #{expected_keys_str}",
            hint: hint
          }
        }

      {:invalid_identity, %{message: message}} ->
        %{
          type: "invalid_identity",
          message: message,
          short_message: "Invalid identity",
          vars: %{},
          path: [:identity],
          fields: [],
          details: %{
            suggestion: "Check the configured identities for this action"
          }
        }

      {:invalid_get_by, %{message: message}} ->
        %{
          type: "invalid_get_by",
          message: message,
          short_message: "Invalid getBy value",
          vars: %{},
          path: [:get_by],
          fields: [],
          details: %{
            suggestion: "Provide a scalar value for each getBy field"
          }
        }

      {:missing_identity, %{expected_keys: expected_keys, identities: identities}} ->
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

        %{
          type: "missing_identity",
          message: message,
          short_message: "Missing identity",
          vars: %{expected_keys: expected_keys_str},
          path: [:identity],
          fields: [],
          details: %{
            expected_keys: expected_keys,
            suggestion: suggestion,
            hint: hint
          }
        }

      # === LIST OF ERRORS (e.g. from Ash.bulk_update BulkResult) ===

      errors when is_list(errors) ->
        Enum.flat_map(errors, fn error ->
          runtime |> build_error_response(error, scope) |> List.wrap()
        end)

      # === REACTOR ERRORS ===

      # Unwrap Reactor RunStepError to get at the inner error
      %Reactor.Error.Invalid.RunStepError{error: inner_error} ->
        inner_error
        |> Ash.Error.to_error_class()
        |> then(&build_error_response(runtime, &1, scope))

      # === ASH FRAMEWORK ERRORS ===

      # Any exception or Ash error - convert to Ash error class and process
      error when is_exception(error) or is_map(error) ->
        ash_error = Ash.Error.to_error_class(error)
        scope = scope || %{}

        # Returns list directly - caller handles both single and multiple errors
        Errors.to_errors(
          runtime,
          ash_error,
          scope[:domain],
          scope[:resource],
          scope[:action],
          scope[:context] || %{}
        )

      # === NESTED RELATIONSHIP QUERY OPTION ERRORS ===

      {:query_opts_on_non_relationship, field, kind, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "invalid_query_opts",
          message:
            "Field %{field} is a %{kind} and does not accept query options (page/filter/sort/limit/offset)",
          short_message: "Invalid query options",
          vars: %{field: full_field_path, kind: to_string(kind)},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            suggestion:
              "Query options are only supported on has_many and many_to_many relationships",
            hint: hint
          }
        }

      {:query_opts_on_to_one, field, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "invalid_query_opts",
          message: "Relationship %{field} is to-one and does not accept query options",
          short_message: "Invalid query options",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            suggestion: "Use a plain nested field list for to-one relationships",
            hint: hint
          }
        }

      {:args_and_query_opts_combined, field, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "invalid_query_opts",
          message: "Field %{field} combines args with query options; they are mutually exclusive",
          short_message: "Invalid query options",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            suggestion: "Remove the args key — relationships do not take arguments"
          }
        }

      {:page_and_limit_offset_combined, field, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "invalid_query_opts",
          message: "Field %{field} combines page with bare limit/offset; use one or the other",
          short_message: "Invalid query options",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            suggestion: "Use page for paginated results or bare limit/offset for a plain slice"
          }
        }

      {:nested_pagination_not_supported, field, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "pagination_not_supported",
          message: "Relationship %{field} does not support pagination",
          short_message: "Pagination not supported",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            reason: :unsupported,
            suggestion:
              "The relationship's read action has no pagination configured. Use bare limit/offset, or add pagination to the destination read action",
            hint: hint
          }
        }

      {:filter_not_supported, :top_level, reason} ->
        %{
          type: "filter_not_supported",
          message: "This action does not support the filter parameter",
          short_message: "Filter not supported",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            reason: reason,
            suggestion:
              "Remove the filter parameter. It is unavailable because the action is not a list read (get?/non-read) or filtering is disabled via enable_filter?: false",
            hint: hint
          }
        }

      {:filter_not_supported, field, reason, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "filter_not_supported",
          message: "Relationship %{field} does not support filtering",
          short_message: "Filter not supported",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            reason: reason,
            suggestion:
              "Remove the filter key. Filtering is unavailable because the RPC action disables it (enable_filter?: false) or the relationship is not filterable?",
            hint: hint
          }
        }

      {:sort_not_supported, :top_level, reason} ->
        %{
          type: "sort_not_supported",
          message: "This action does not support the sort parameter",
          short_message: "Sort not supported",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            reason: reason,
            suggestion:
              "Remove the sort parameter. It is unavailable because the action is not a list read (get?/non-read) or sorting is disabled via enable_sort?: false",
            hint: hint
          }
        }

      {:sort_not_supported, field, reason, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "sort_not_supported",
          message: "Relationship %{field} does not support sorting",
          short_message: "Sort not supported",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            reason: reason,
            suggestion:
              "Remove the sort key. Sorting is unavailable because the RPC action disables it (enable_sort?: false) or the relationship is not sortable?",
            hint: hint
          }
        }

      {:pagination_not_supported, :top_level, reason} ->
        %{
          type: "pagination_not_supported",
          message: "This action does not support the page parameter",
          short_message: "Pagination not supported",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            reason: reason,
            suggestion:
              "Remove the page parameter. It is unavailable because the action is not a list read (get?/non-read) or has no pagination configured",
            hint: hint
          }
        }

      {:invalid_nested_page, field, reason, path} when is_list(path) ->
        full_field_path = build_complete_field_path(path, field, formatter)

        %{
          type: "invalid_pagination",
          message: "Invalid page configuration for relationship %{field}",
          short_message: "Invalid pagination",
          vars: %{field: full_field_path},
          path: format_path(path, formatter),
          fields: [full_field_path],
          details: %{
            reason: inspect(reason),
            suggestion:
              "Provide page keys valid for the relationship's pagination type (offset: limit/offset/count, keyset: limit/after/before/count)",
            hint: hint
          }
        }

      # === FIELD TYPE ERRORS ===

      # Invalid field type errors (from validator throws)
      {:invalid_field_type, field_name, path} ->
        formatted_path = format_path(path, formatter)
        field_path = build_complete_field_path(path, field_name, formatter)

        %{
          type: "unknown_field",
          message: "Unknown field %{field}",
          short_message: "Unknown field",
          vars: %{field: field_path},
          path: formatted_path,
          fields: [field_path],
          details: %{
            suggestion: "Check that the field exists and is accessible",
            hint: hint
          }
        }

      {field_error_type, _} when is_atom(field_error_type) ->
        %{
          type: "field_validation_error",
          message: "Field validation error: %{error_type}",
          short_message: "Field validation error",
          vars: %{error_type: to_string(field_error_type)},
          path: [],
          fields: [],
          details: %{
            error: inspect(error),
            hint: hint
          }
        }

      other ->
        %{
          type: "unknown_error",
          message: "An unexpected error occurred",
          short_message: "Unknown error",
          vars: %{},
          path: [],
          fields: [],
          details: %{
            error: inspect(other)
          }
        }
    end
  end

  defp stale_client_hint(%{profile: nil}), do: AshRpc.Profile.default_stale_client_hint()
  defp stale_client_hint(%{profile: profile}), do: profile.stale_client_hint()

  defp drop_nil_hint(%{details: %{hint: nil} = details} = error),
    do: %{error | details: Map.delete(details, :hint)}

  defp drop_nil_hint(error), do: error

  defp format_field_type(:primitive_type), do: "primitive type"
  defp format_field_type(%Ash.Info.Manifest.Type{name: name}) when is_binary(name), do: name
  defp format_field_type({:ash_type, type, _}), do: "#{inspect(type)}"
  defp format_field_type(other), do: "#{inspect(other)}"

  defp format_path(path, formatter) when is_list(path) do
    Enum.map(path, fn field ->
      AshRpc.FieldFormatter.format_field_name(to_string(field), formatter)
    end)
  end

  defp format_field_name(field_name, formatter) when is_atom(field_name) do
    format_field_name(to_string(field_name), formatter)
  end

  defp format_field_name(field_name, formatter) when is_binary(field_name) do
    AshRpc.FieldFormatter.format_field_name(field_name, formatter)
  end

  defp build_complete_field_path(path, field_name, formatter) when is_list(path) do
    formatted_path = format_path(path, formatter)
    formatted_field = format_field_name(field_name, formatter)

    case formatted_path do
      [] -> formatted_field
      _ -> Enum.join(formatted_path ++ [formatted_field], ".")
    end
  end
end
