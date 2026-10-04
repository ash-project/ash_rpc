# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorBuilderGoldenTest do
  @moduledoc false
  # Wire output of every AshRpc.ErrorBuilder clause, captured before the error
  # modules were refactored. Any diff here is a wire change for clients.
  use ExUnit.Case, async: true

  alias AshRpc.Test.ErrorCases

  @golden %{
    "sort_not_supported_top_level" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :unsupported,
            "suggestion" =>
              "Remove the sort parameter. It is unavailable because the action is not a list read (get?/non-read) or sorting is disabled via enable_sort?: false"
          },
          "fields" => [],
          "message" => "This action does not support the sort parameter",
          "path" => [],
          "shortMessage" => "Sort not supported",
          "type" => "sort_not_supported",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "empty_fields_array" => %{
      "errors" => [
        %{
          "details" => %{"suggestion" => "Provide at least one field name in the fields array"},
          "fields" => [],
          "message" => "Fields array cannot be empty",
          "path" => [],
          "shortMessage" => "Empty fields array",
          "type" => "empty_fields_array",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "reactor_run_step_error" => %{
      "errors" => [
        %{
          "fields" => [],
          "message" => "record not found",
          "path" => [],
          "shortMessage" => "Not found",
          "type" => "not_found",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "invalid_union_input_multiple_member_keys" => %{
      "errors" => [
        %{
          "details" => %{
            "suggestion" =>
              "Provide exactly one member key, not multiple. Choose one of: %{expectedMembers}"
          },
          "fields" => [],
          "message" => "Union input map contains multiple member keys: %{foundKeys}",
          "path" => [],
          "shortMessage" => "Invalid union input",
          "type" => "invalid_union_input",
          "vars" => %{"expectedMembers" => "text, number", "foundKeys" => "text, number"}
        }
      ],
      "success" => false
    },
    "unknown_field_kind" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Check that the field name is valid for the type's field constraints"
          },
          "fields" => ["postStats.nope"],
          "message" => "Unknown field %{field} for %{kind} type",
          "path" => ["postStats"],
          "shortMessage" => "Unknown field",
          "type" => "unknown_field",
          "vars" => %{"field" => "postStats.nope", "kind" => "field constrained"}
        }
      ],
      "success" => false
    },
    "unknown_map_field" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Check that the field name is valid for the map's field constraints"
          },
          "fields" => ["postStats.wordCount"],
          "message" => "Unknown field %{field} for map return type",
          "path" => ["postStats"],
          "shortMessage" => "Unknown map field",
          "type" => "unknown_map_field",
          "vars" => %{"field" => "postStats.wordCount"}
        }
      ],
      "success" => false
    },
    "invalid_get_by" => %{
      "errors" => [
        %{
          "details" => %{"suggestion" => "Provide a scalar value for each getBy field"},
          "fields" => [],
          "message" => "bad get_by",
          "path" => [:get_by],
          "shortMessage" => "Invalid getBy value",
          "type" => "invalid_get_by",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "unsupported_field_combination" => %{
      "errors" => [
        %{
          "details" => %{
            "fieldSpec" => "\"spec\"",
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Check the documentation for valid field specification formats"
          },
          "fields" => ["author"],
          "message" => "Unsupported combination of field type and specification for %{field}",
          "path" => [],
          "shortMessage" => "Unsupported field combination",
          "type" => "unsupported_field_combination",
          "vars" => %{"field" => "author", "fieldType" => "relationship"}
        }
      ],
      "success" => false
    },
    "missing_required_parameter" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Ensure %{parameter} parameter is provided and not empty"
          },
          "fields" => [],
          "message" => "Required parameter %{parameter} is missing or empty",
          "path" => [],
          "shortMessage" => "Missing required parameter",
          "type" => "missing_required_parameter",
          "vars" => %{"parameter" => "action"}
        }
      ],
      "success" => false
    },
    "calculation_requires_args" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Provide arguments in the format: {\"full_name\": {\"args\": {...}}}"
          },
          "fields" => ["author.fullName"],
          "message" => "Calculation %{field} requires arguments",
          "path" => ["author"],
          "shortMessage" => "Calculation requires arguments",
          "type" => "invalid_field_format",
          "vars" => %{"field" => "author.fullName"}
        }
      ],
      "success" => false
    },
    "unknown_error" => %{
      "errors" => [
        %{
          "details" => %{"error" => "\"boom\""},
          "fields" => [],
          "message" => "An unexpected error occurred",
          "path" => [],
          "shortMessage" => "Unknown error",
          "type" => "unknown_error",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "missing_identity_many" => %{
      "errors" => [
        %{
          "details" => %{
            "expectedKeys" => ["id", "slug"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Provide identity fields for one of the configured identities: id, slug"
          },
          "fields" => [],
          "message" =>
            "Identity is required but not provided. Expected one of: [%{expectedKeys}]",
          "path" => [:identity],
          "shortMessage" => "Missing identity",
          "type" => "missing_identity",
          "vars" => %{"expectedKeys" => "id, slug"}
        }
      ],
      "success" => false
    },
    "requires_field_selection_pathless" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Specify which fields to select from this field_constrained_type"
          },
          "fields" => [],
          "message" => "%{fieldType} requires field selection",
          "path" => [],
          "shortMessage" => "Field selection required",
          "type" => "requires_field_selection",
          "vars" => %{"fieldType" => "Field_constrained_type"}
        }
      ],
      "success" => false
    },
    "missing_get_by_fields" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Provide values for all required getBy fields"
          },
          "fields" => ["title"],
          "message" => "Required getBy fields are missing: %{fields}",
          "path" => [:get_by],
          "shortMessage" => "Missing required getBy fields",
          "type" => "missing_required_input",
          "vars" => %{"fields" => "title"}
        }
      ],
      "success" => false
    },
    "field_does_not_support_nesting" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Remove the nested specification for this field"
          },
          "fields" => ["post.title"],
          "message" => "Field %{field} does not support nested field selection",
          "path" => ["post"],
          "shortMessage" => "Field does not support nesting",
          "type" => "field_does_not_support_nesting",
          "vars" => %{"field" => "post.title"}
        }
      ],
      "success" => false
    },
    "ash_exception" => %{
      "errors" => [
        %{
          "fields" => [],
          "message" => "record not found",
          "path" => [],
          "shortMessage" => "Not found",
          "type" => "not_found",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "invalid_identity_keys" => %{
      "errors" => [
        %{
          "details" => %{
            "expectedKeys" => ["id"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "providedKeys" => ["slug"],
            "suggestion" => "Provide all required fields for one of the configured identities: id"
          },
          "fields" => [],
          "message" =>
            "Identity fields do not match any configured identity. Provided: [%{providedKeys}], expected: [%{expectedKeys}]",
          "path" => [:identity],
          "shortMessage" => "Invalid identity",
          "type" => "invalid_identity",
          "vars" => %{"expectedKeys" => "id", "providedKeys" => "slug"}
        }
      ],
      "success" => false
    },
    "load_not_allowed" => %{
      "errors" => [
        %{
          "details" => %{
            "disallowedPaths" => ["author.posts"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Remove these fields from your request or check allowed_loads configuration"
          },
          "fields" => ["author.posts"],
          "message" => "Loading the following fields is not allowed: %{fields}",
          "path" => [],
          "shortMessage" => "Load not allowed",
          "type" => "load_not_allowed",
          "vars" => %{"fields" => "author.posts"}
        }
      ],
      "success" => false
    },
    "unknown_union_field" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Check that the union member name is valid for the union attribute definition"
          },
          "fields" => ["content.textMember"],
          "message" => "Unknown union member %{field}",
          "path" => ["content"],
          "shortMessage" => "Unknown union member",
          "type" => "unknown_union_field",
          "vars" => %{"field" => "content.textMember"}
        }
      ],
      "success" => false
    },
    "unknown_page_keys" => %{
      "errors" => [
        %{
          "details" => %{
            "expected" =>
              "Offset pagination (limit, offset, count) or keyset pagination (limit, after, before)"
          },
          "fields" => ["pageSize"],
          "message" => "Unknown pagination keys: %{keys}",
          "path" => ["page"],
          "shortMessage" => "Invalid pagination",
          "type" => "invalid_pagination",
          "vars" => %{"keys" => "pageSize"}
        }
      ],
      "success" => false
    },
    "invalid_field_selection" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Remove the field selection for this :attribute field"
          },
          "fields" => ["post.viewCount"],
          "message" => "Cannot select fields from %{fieldType} %{field}",
          "path" => ["post"],
          "shortMessage" => "Invalid field selection",
          "type" => "invalid_field_selection",
          "vars" => %{"field" => "post.viewCount", "fieldType" => ":attribute"}
        }
      ],
      "success" => false
    },
    "invalid_identity_message" => %{
      "errors" => [
        %{
          "details" => %{"suggestion" => "Check the configured identities for this action"},
          "fields" => [],
          "message" => "bad identity",
          "path" => [:identity],
          "shortMessage" => "Invalid identity",
          "type" => "invalid_identity",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "invalid_field_selection_primitive" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "requestedFields" => ["x"],
            "suggestion" => "Remove the field selection for this primitive type"
          },
          "fields" => [],
          "message" => "Cannot select fields from primitive type %{returnType}",
          "path" => [],
          "shortMessage" => "Invalid field selection",
          "type" => "invalid_field_selection",
          "vars" => %{"returnType" => "Integer"}
        }
      ],
      "success" => false
    },
    "page_and_limit_offset_combined" => %{
      "errors" => [
        %{
          "details" => %{
            "suggestion" =>
              "Use page for paginated results or bare limit/offset for a plain slice"
          },
          "fields" => ["posts"],
          "message" =>
            "Field %{field} combines page with bare limit/offset; use one or the other",
          "path" => [],
          "shortMessage" => "Invalid query options",
          "type" => "invalid_query_opts",
          "vars" => %{"field" => "posts"}
        }
      ],
      "success" => false
    },
    "ash_error_class" => %{
      "errors" => [
        %{
          "fields" => [],
          "message" => "record not found",
          "path" => [],
          "shortMessage" => "Not found",
          "type" => "not_found",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "invalid_field_selection_primitive_nil" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "requestedFields" => ["x"],
            "suggestion" => "Remove the field selection for this primitive type"
          },
          "fields" => [],
          "message" => "Cannot select fields from primitive type %{returnType}",
          "path" => ["post"],
          "shortMessage" => "Invalid field selection",
          "type" => "invalid_field_selection",
          "vars" => %{"returnType" => "nil"}
        }
      ],
      "success" => false
    },
    "invalid_calculation_args" => %{
      "errors" => [
        %{
          "details" => %{
            "expected" => "Map containing argument values or valid field selection format",
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes."
          },
          "fields" => ["fullName"],
          "message" => "Invalid arguments for calculation %{field}",
          "path" => [],
          "shortMessage" => "Invalid calculation arguments",
          "type" => "invalid_calculation_args",
          "vars" => %{"field" => "fullName"}
        }
      ],
      "success" => false
    },
    "duplicate_field" => %{
      "errors" => [
        %{
          "details" => %{"suggestion" => "Remove duplicate field specifications"},
          "fields" => ["post.viewCount"],
          "message" => "Field %{field} was requested multiple times",
          "path" => ["post"],
          "shortMessage" => "Duplicate field",
          "type" => "duplicate_field",
          "vars" => %{"field" => "post.viewCount"}
        }
      ],
      "success" => false
    },
    "list" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Check that the action is properly configured in your domain's rpc block"
          },
          "fields" => [],
          "message" => "RPC action %{actionName} not found",
          "path" => [],
          "shortMessage" => "Action not found",
          "type" => "action_not_found",
          "vars" => %{"actionName" => "a"}
        },
        %{
          "fields" => [],
          "message" => "record not found",
          "path" => [],
          "shortMessage" => "Not found",
          "type" => "not_found",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "action_not_found" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Check that the action is properly configured in your domain's rpc block"
          },
          "fields" => [],
          "message" => "RPC action %{actionName} not found",
          "path" => [],
          "shortMessage" => "Action not found",
          "type" => "action_not_found",
          "vars" => %{"actionName" => "list_postz"}
        }
      ],
      "success" => false
    },
    "invalid_input_format" => %{
      "errors" => [
        %{
          "details" => %{"expected" => "Map containing input parameters"},
          "fields" => [],
          "message" => "Input parameter must be a map",
          "path" => [],
          "shortMessage" => "Invalid input format",
          "type" => "invalid_input_format",
          "vars" => %{"received" => "\"x\""}
        }
      ],
      "success" => false
    },
    "unknown_field_resource" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Check the field name spelling and ensure it's a public attribute, calculation, or relationship"
          },
          "fields" => ["author.userName"],
          "message" => "Unknown field %{field} for resource %{resource}",
          "path" => ["author"],
          "shortMessage" => "Unknown field",
          "type" => "unknown_field",
          "vars" => %{"field" => "author.userName", "resource" => "AshRpc.Test.Post"}
        }
      ],
      "success" => false
    },
    "missing_identity_primary_key" => %{
      "errors" => [
        %{
          "details" => %{
            "expectedKeys" => ["id"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Pass the id value directly as the identity field (e.g., identity: \"your-id-here\")"
          },
          "fields" => [],
          "message" => "Identity is required. Provide the id value directly.",
          "path" => [:identity],
          "shortMessage" => "Missing identity",
          "type" => "missing_identity",
          "vars" => %{"expectedKeys" => "id"}
        }
      ],
      "success" => false
    },
    "invalid_field_type" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Check that the field exists and is accessible"
          },
          "fields" => ["author.userName"],
          "message" => "Unknown field %{field}",
          "path" => ["author"],
          "shortMessage" => "Unknown field",
          "type" => "unknown_field",
          "vars" => %{"field" => "author.userName"}
        }
      ],
      "success" => false
    },
    "invalid_union_input_no_member_key" => %{
      "errors" => [
        %{
          "details" => %{
            "expectedMembers" => ["text", "number"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Provide exactly one of the following keys: %{expectedMembers}"
          },
          "fields" => [],
          "message" => "Union input map does not contain any valid member key",
          "path" => [],
          "shortMessage" => "Invalid union input",
          "type" => "invalid_union_input",
          "vars" => %{"expectedMembers" => "text, number"}
        }
      ],
      "success" => false
    },
    "filter_not_supported_top_level" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :disabled,
            "suggestion" =>
              "Remove the filter parameter. It is unavailable because the action is not a list read (get?/non-read) or filtering is disabled via enable_filter?: false"
          },
          "fields" => [],
          "message" => "This action does not support the filter parameter",
          "path" => [],
          "shortMessage" => "Filter not supported",
          "type" => "filter_not_supported",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "sort_not_supported_nested" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :disabled,
            "suggestion" =>
              "Remove the sort key. Sorting is unavailable because the RPC action disables it (enable_sort?: false) or the relationship is not sortable?"
          },
          "fields" => ["author.posts"],
          "message" => "Relationship %{field} does not support sorting",
          "path" => ["author"],
          "shortMessage" => "Sort not supported",
          "type" => "sort_not_supported",
          "vars" => %{"field" => "author.posts"}
        }
      ],
      "success" => false
    },
    "args_and_query_opts_combined" => %{
      "errors" => [
        %{
          "details" => %{
            "suggestion" => "Remove the args key — relationships do not take arguments"
          },
          "fields" => ["posts"],
          "message" =>
            "Field %{field} combines args with query options; they are mutually exclusive",
          "path" => [],
          "shortMessage" => "Invalid query options",
          "type" => "invalid_query_opts",
          "vars" => %{"field" => "posts"}
        }
      ],
      "success" => false
    },
    "requires_field_selection" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Specify which fields to select from this relationship"
          },
          "fields" => ["post.author"],
          "message" => "%{fieldType} %{field} requires field selection",
          "path" => ["post"],
          "shortMessage" => "Field selection required",
          "type" => "requires_field_selection",
          "vars" => %{"field" => "post.author", "fieldType" => "Relationship"}
        }
      ],
      "success" => false
    },
    "query_opts_on_to_one" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Use a plain nested field list for to-one relationships"
          },
          "fields" => ["author"],
          "message" => "Relationship %{field} is to-one and does not accept query options",
          "path" => [],
          "shortMessage" => "Invalid query options",
          "type" => "invalid_query_opts",
          "vars" => %{"field" => "author"}
        }
      ],
      "success" => false
    },
    "invalid_field_format" => %{
      "errors" => [
        %{
          "details" => %{
            "fieldSpec" => "%{\"self\" => %{\"args\" => %{}}}",
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Check the documentation for valid field specification formats"
          },
          "fields" => [],
          "message" => "Invalid field specification format",
          "path" => ["author"],
          "shortMessage" => "Invalid field format",
          "type" => "invalid_field_format",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "invalid_pagination" => %{
      "errors" => [
        %{
          "details" => %{
            "expected" => "Map with pagination parameters (limit, offset, before, after, etc.)"
          },
          "fields" => [],
          "message" => "Invalid pagination parameter format",
          "path" => [],
          "shortMessage" => "Invalid pagination",
          "type" => "invalid_pagination",
          "vars" => %{"received" => "\"x\""}
        }
      ],
      "success" => false
    },
    "load_denied" => %{
      "errors" => [
        %{
          "details" => %{
            "deniedPaths" => ["secret"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Remove these fields from your request"
          },
          "fields" => ["secret"],
          "message" => "Loading the following fields is denied: %{fields}",
          "path" => [],
          "shortMessage" => "Load denied",
          "type" => "load_denied",
          "vars" => %{"fields" => "secret"}
        }
      ],
      "success" => false
    },
    "pagination_not_supported_top_level" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :unsupported,
            "suggestion" =>
              "Remove the page parameter. It is unavailable because the action is not a list read (get?/non-read) or has no pagination configured"
          },
          "fields" => [],
          "message" => "This action does not support the page parameter",
          "path" => [],
          "shortMessage" => "Pagination not supported",
          "type" => "pagination_not_supported",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "field_validation_error" => %{
      "errors" => [
        %{
          "details" => %{
            "error" => "{:some_validation_failure, :x}",
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes."
          },
          "fields" => [],
          "message" => "Field validation error: %{errorType}",
          "path" => [],
          "shortMessage" => "Field validation error",
          "type" => "field_validation_error",
          "vars" => %{"errorType" => "some_validation_failure"}
        }
      ],
      "success" => false
    },
    "unexpected_get_by_fields" => %{
      "errors" => [
        %{
          "details" => %{
            "allowedFields" => ["title"],
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Only provide the allowed getBy fields: %{allowedFields}"
          },
          "fields" => ["viewCount"],
          "message" =>
            "Unexpected getBy fields: %{extraFields}. Allowed fields: %{allowedFields}",
          "path" => [:get_by],
          "shortMessage" => "Unexpected getBy fields",
          "type" => "unexpected_get_by_fields",
          "vars" => %{"allowedFields" => "title", "extraFields" => "viewCount"}
        }
      ],
      "success" => false
    },
    "query_opts_on_non_relationship" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" =>
              "Query options are only supported on has_many and many_to_many relationships"
          },
          "fields" => ["posts.title"],
          "message" =>
            "Field %{field} is a %{kind} and does not accept query options (page/filter/sort/limit/offset)",
          "path" => ["posts"],
          "shortMessage" => "Invalid query options",
          "type" => "invalid_query_opts",
          "vars" => %{"field" => "posts.title", "kind" => "attribute"}
        }
      ],
      "success" => false
    },
    "invalid_fields_type" => %{
      "errors" => [
        %{
          "details" => %{
            "expectedCode" => "array",
            "suggestion" => "Wrap field names in an array, e.g., [\"field1\", \"field2\"]"
          },
          "fields" => [],
          "message" => "Fields parameter must be an array",
          "path" => [],
          "shortMessage" => "Invalid fields type",
          "type" => "invalid_fields_type",
          "vars" => %{"received" => "\"title\""}
        }
      ],
      "success" => false
    },
    "nested_pagination_not_supported" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :unsupported,
            "suggestion" =>
              "The relationship's read action has no pagination configured. Use bare limit/offset, or add pagination to the destination read action"
          },
          "fields" => ["posts"],
          "message" => "Relationship %{field} does not support pagination",
          "path" => [],
          "shortMessage" => "Pagination not supported",
          "type" => "pagination_not_supported",
          "vars" => %{"field" => "posts"}
        }
      ],
      "success" => false
    },
    "invalid_union_input_not_a_map" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "suggestion" => "Provide union input in the format: {\"member_name\": value}"
          },
          "fields" => [],
          "message" => "Union input must be a map with exactly one member key",
          "path" => [],
          "shortMessage" => "Invalid union input",
          "type" => "invalid_union_input",
          "vars" => %{}
        }
      ],
      "success" => false
    },
    "filter_not_supported_nested" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => :disabled,
            "suggestion" =>
              "Remove the filter key. Filtering is unavailable because the RPC action disables it (enable_filter?: false) or the relationship is not filterable?"
          },
          "fields" => ["author.posts"],
          "message" => "Relationship %{field} does not support filtering",
          "path" => ["author"],
          "shortMessage" => "Filter not supported",
          "type" => "filter_not_supported",
          "vars" => %{"field" => "author.posts"}
        }
      ],
      "success" => false
    },
    "invalid_nested_page" => %{
      "errors" => [
        %{
          "details" => %{
            "hint" =>
              "This error is most likely happening because the generated client used is not up to date with the running backend. Check that you are using the latest generated client, and/or that it has been regenerated after the last backend changes.",
            "reason" => "{:unknown_keys, [\"x\"]}",
            "suggestion" =>
              "Provide page keys valid for the relationship's pagination type (offset: limit/offset/count, keyset: limit/after/before/count)"
          },
          "fields" => ["posts"],
          "message" => "Invalid page configuration for relationship %{field}",
          "path" => [],
          "shortMessage" => "Invalid pagination",
          "type" => "invalid_pagination",
          "vars" => %{"field" => "posts"}
        }
      ],
      "success" => false
    }
  }

  test "the snapshot covers every case" do
    assert ErrorCases.cases() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             @golden |> Map.keys() |> Enum.sort()
  end

  for {label, _reason} <- ErrorCases.cases() do
    test "wire output for #{label} is unchanged" do
      {_, reason} = List.keyfind(ErrorCases.cases(), unquote(label), 0)

      assert AshRpc.error_response(AshRpc.Test.Profile, reason) ==
               Map.fetch!(@golden, unquote(label))
    end
  end
end
