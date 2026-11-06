# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defprotocol AshRpc.Error do
  @moduledoc """
  Protocol for extracting minimal information from exceptions for RPC responses.

  Similar to AshGraphql.Error, this protocol transforms various error types into
  a standardized format with only the essential information needed by clients.

  ## Error Format

  Each implementation should return a map with these fields:
  - `:message` - The full error message (may contain template variables like %{key})
  - `:short_message` - A concise version of the message
  - `:type` - A machine-readable error type (e.g., "invalid_changes", "not_found")
  - `:vars` - A map of variables to interpolate into messages
  - `:fields` - A list of affected field names (for field-level errors)
  - `:path` - The path to the error location in the data structure
  - `:details` - (optional) A map with extra details, e.g. `:suggestion`

  ## Example Implementation

      defimpl AshRpc.Error, for: MyApp.CustomError do
        def to_error(error) do
          %{
            message: error.message,
            short_message: "Custom error occurred",
            type: "custom_error",
            vars: %{detail: error.detail},
            fields: [],
            path: error.path || []
          }
        end
      end
  """

  @doc """
  Transforms an exception into a minimal error representation for RPC responses.
  """
  @spec to_error(Exception.t()) :: map()
  def to_error(exception)
end

defimpl AshRpc.Error, for: Ash.Error.Changes.InvalidChanges do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid changes",
      vars: Map.new(error.vars || []),
      type: "invalid_changes",
      fields: List.wrap(error.fields),
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Query.InvalidQuery do
  # Exception.message/1 on an InvalidQuery without a message inspects the whole
  # struct, offending value included, so fall back to a static message.
  def to_error(error) do
    %{
      message: Map.get(error, :message) || "Invalid query",
      short_message: "Invalid query",
      vars: Map.new(error.vars || []),
      type: "invalid_query",
      fields: List.wrap(Map.get(error, :fields) || Map.get(error, :field)),
      path: error.path || []
    }
  end
end

# An input the action doesn't accept, including a private (`public? false`)
# argument. `input` is the key as the client sent it. It is always a top-level
# action input, so the path Ash sets (an input index) is dropped.
defimpl AshRpc.Error, for: Ash.Error.Invalid.NoSuchInput do
  def to_error(error) do
    %{
      message: "Unknown input %{field}",
      short_message: "Unknown input",
      vars: %{field: error.input},
      type: "unknown_input",
      fields: [error.input],
      path: []
    }
  end
end

# A filter or sort name that is not a client name of the resource.
# `AshRpc.FilterInput` reports these misses as Ash's NoSuchField, naming the
# field as the client sent it, with `path` where it sits: `[:sort]`, or the
# filter path to its parent (`[:filter, "author", "posts"]`).
defimpl AshRpc.Error, for: Ash.Error.Query.NoSuchField do
  def to_error(error) do
    field = to_string(error.field)

    %{
      message: "Unknown field %{field}",
      short_message: "Unknown field",
      vars: %{field: field},
      type: "unknown_field",
      fields: [field],
      path: error.path || []
    }
  end
end

# A filter operator the field doesn't support, named as the client sent it
defimpl AshRpc.Error, for: Ash.Error.Query.NoSuchFilterPredicate do
  def to_error(error) do
    operator = to_string(error.key)

    %{
      message: "Unknown filter operator %{operator}",
      short_message: "Unknown filter operator",
      vars: %{operator: operator},
      type: "unknown_filter_operator",
      fields: [operator],
      path: error.path || []
    }
  end
end

# A sort that is not a string or a list of strings (`AshRpc.FilterInput`), or
# one Ash rejects. The rejected value is not echoed back: Ash's own uses hold
# internal names.
defimpl AshRpc.Error, for: Ash.Error.Query.InvalidSort do
  def to_error(error) do
    %{
      message: "Invalid sort",
      short_message: "Invalid sort",
      vars: %{},
      type: "invalid_sort",
      fields: [],
      path: error.path || [],
      details: %{
        expected:
          "A string or a list of strings, each a field name with an optional +, -, ++ or -- prefix"
      }
    }
  end
end

# A calculation argument value Ash rejects, or a missing required one. From
# field selection the path is Ash's (`[:load]`, `[:load, relationship]`) and
# continues at the calculation's `args`, where `AshRpc.Errors` names the
# argument. `AshRpc.FilterInput` checks filter arguments itself, with the full
# path, so `[:filter]` (and `[:sort]`) only come from server-side callers: the
# path continues at the calculation (and its `input`). The message is fixed:
# a type's cast error string could echo the value.
defimpl AshRpc.Error, for: Ash.Error.Query.InvalidCalculationArgument do
  def to_error(error) do
    path = error.path || []

    suffix =
      case List.last(path) do
        :filter -> [error.calculation, :input]
        :sort -> [error.calculation]
        _ -> [error.calculation, :args]
      end

    %{
      message: if(error.message == "is required", do: "is required", else: "is invalid"),
      short_message: "Invalid calculation argument",
      vars: %{field: error.field},
      type: "invalid_calculation_argument",
      fields: [error.field],
      path: path ++ suffix
    }
  end
end

# A filter value Ash rejects. `AshRpc.FilterInput` reports what it can check
# (an `in` that is not a list, a value the operator's or the field's type
# can't cast, a boolean statement) with its full path; whatever Ash still
# rejects has only Ash's `[:filter]`. Ash's message names internal fields and
# echoes the value, so it is dropped.
defimpl AshRpc.Error, for: Ash.Error.Query.InvalidFilterValue do
  def to_error(error) do
    %{
      message: "Invalid filter value",
      short_message: "Invalid filter value",
      vars: %{},
      type: "invalid_filter_value",
      fields: [],
      path: error.path || [],
      details: %{}
    }
  end
end

# A sort field that can't be sorted on. `AshRpc.FilterInput` reports
# relationships (`reason` `:relationship`), calculations with required
# arguments (`:requires_arguments`) and fields the manifest marks unsortable,
# naming the field as sent; Ash reports others by internal name (`:type`,
# `:to_many`), which `AshRpc.Errors` names for the client. Ash's message names
# the resource module, so it is not used.
defimpl AshRpc.Error, for: Ash.Error.Query.UnsortableField do
  def to_error(error) do
    %{
      message: "Cannot sort on %{field}",
      short_message: "Unsortable field",
      vars: %{field: error.field},
      type: "unsortable_field",
      fields: [error.field],
      path: error.path || [],
      details: if(error.reason, do: %{reason: to_string(error.reason)}, else: %{})
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Query.NotFound do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Not found",
      vars: Map.new(error.vars || []),
      type: "not_found",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: [Ash.Error.Changes.Required, Ash.Error.Query.Required] do
  # A template: Ash's own message names the field in server casing, while
  # vars.field carries the client name.
  def to_error(error) do
    %{
      message: required_message(error.type),
      short_message: "Required field",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "required",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end

  defp required_message(type) when is_atom(type) and not is_nil(type),
    do: "#{type} %{field} is required"

  defp required_message(_type), do: "%{field} is required"
end

defimpl AshRpc.Error, for: Ash.Error.Forbidden.Policy do
  # Breakdowns are applied by AshRpc.Errors when the profile's
  # show_policy_breakdowns?/0 is true, so the protocol never leaks one.
  def to_error(error) do
    %{
      message: "forbidden",
      short_message: "Forbidden",
      vars: Map.new(error.vars),
      type: "forbidden",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Forbidden.ForbiddenField do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Forbidden field",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "forbidden_field",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Changes.InvalidAttribute do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid attribute",
      vars: Map.new(error.vars || []) |> Map.put(:field, error.field),
      type: "invalid_attribute",
      fields: List.wrap(error.field),
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error,
  for: [
    Ash.Error.Changes.InvalidArgument,
    Ash.Error.Query.InvalidArgument,
    Ash.Error.Action.InvalidArgument
  ] do
  def to_error(error) do
    %{
      message: Map.get(error, :message) || Exception.message(error),
      short_message: "Invalid argument",
      vars: Map.new(error.vars || []) |> Map.put(:field, Map.get(error, :field)),
      type: "invalid_argument",
      fields: List.wrap(Map.get(error, :field)),
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Page.InvalidKeyset do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid keyset",
      vars: Map.new(error.vars || []),
      type: "invalid_keyset",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Query.InvalidPage do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid pagination",
      vars: Map.new(error.vars || []),
      type: "invalid_page",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Invalid.TenantRequired do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Tenant required",
      vars: Map.new(error.vars || []),
      type: "tenant_required",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Invalid.InvalidPrimaryKey do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Invalid primary key",
      vars: Map.new(error.vars || []),
      type: "invalid_primary_key",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Query.ReadActionRequiresActor do
  def to_error(error) do
    %{
      message: Exception.message(error),
      short_message: "Authentication required",
      vars: Map.new(error.vars || []),
      type: "forbidden",
      fields: [],
      path: error.path || []
    }
  end
end

defimpl AshRpc.Error, for: Ash.Error.Unknown.UnknownError do
  def to_error(error) do
    %{
      message: "Something went wrong",
      short_message: "Unknown error",
      vars: Map.new(error.vars || []),
      type: "unknown_error",
      fields: [],
      path: error.path || []
    }
  end
end
