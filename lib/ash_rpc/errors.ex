# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Errors do
  @moduledoc """
  Central error processing module for RPC operations.

  Handles error transformation, unwrapping, and formatting for RPC clients.
  Uses the AshRpc.Error protocol to extract minimal information from exceptions.
  """

  require Logger

  alias AshRpc.ClientPath
  alias AshRpc.Error, as: ErrorProtocol

  @doc """
  Transforms errors into standardized RPC error responses.

  Processes errors through the following pipeline:
  1. Convert to Ash error class using Ash.Error.to_error_class
  2. Unwrap nested error structures and clear their bread crumbs
  3. Transform via Error protocol (or expose the raised message when the
     profile's `show_raised_errors?/1` is true for the domain)
  4. Replace policy messages with a breakdown when the profile's
     `show_policy_breakdowns?/0` is true, and add the profile's
     `stale_client_hint/0` to unknown inputs, filter/sort fields and filter
     operators
  5. Apply resource-level error handler (if configured)
  6. Apply the profile's `error_handler/1` for the domain (`nil` included)

  A handler returning `nil` drops the error; later handlers are skipped.
  """
  @spec to_errors(AshRpc.Runtime.t(), term(), atom() | nil, atom() | nil, atom() | nil, map()) ::
          list(map())
  def to_errors(runtime, errors, domain \\ nil, resource \\ nil, action \\ nil, context \\ %{})

  def to_errors(runtime, errors, domain, resource, action, context) do
    errors
    |> Ash.Error.to_error_class()
    |> unwrap_errors()
    |> Enum.map(&drop_bread_crumbs/1)
    |> Enum.map(&process_single_error(&1, runtime, domain, resource, context))
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&format_error_field_names(&1, resource, action, runtime))
  end

  @doc """
  Unwraps nested error structures from Ash error classes.
  """
  @spec unwrap_errors(term()) :: list(term())
  # A Reactor-run generic action fails with an error class wrapping the step's
  # RunStepError; the step's own error is what the client should see.
  def unwrap_errors(%Reactor.Error.Invalid.RunStepError{error: inner_error}) do
    inner_error |> Ash.Error.to_error_class() |> unwrap_errors()
  end

  def unwrap_errors(%{errors: errors}) when is_list(errors) do
    Enum.flat_map(errors, &unwrap_errors/1)
  end

  def unwrap_errors(%{errors: error}) when not is_list(error) do
    unwrap_errors([error])
  end

  def unwrap_errors(errors) when is_list(errors) do
    Enum.flat_map(errors, &unwrap_errors/1)
  end

  def unwrap_errors(error) do
    [error]
  end

  # Splode renders bread crumbs ("Returned from bulk update: …") into
  # Exception.message/1; they describe server internals, not the client's input.
  defp drop_bread_crumbs(%{bread_crumbs: [_ | _]} = error) when is_exception(error),
    do: %{error | bread_crumbs: []}

  defp drop_bread_crumbs(error), do: error

  defp process_single_error(error, runtime, domain, resource, context) do
    transformed_error =
      if profile_show_raised_errors?(runtime, domain) and is_exception(error) do
        raised_error(error)
      else
        protocol_error(error)
      end

    transformed_error =
      transformed_error
      |> maybe_policy_breakdown(error, runtime)
      |> maybe_stale_client_hint(error, runtime)

    [resource_error_handler(resource), profile_error_handler(runtime, domain)]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(transformed_error, fn handler, error ->
      case apply_error_handler(handler, error, context) do
        nil -> {:halt, nil}
        handled -> {:cont, handled}
      end
    end)
  end

  defp resource_error_handler(resource) do
    if resource && function_exported?(resource, :handle_rpc_error, 2),
      do: {resource, :handle_rpc_error, []}
  end

  # show_raised_errors? exposes the actual exception message
  defp raised_error(error) do
    name = error.__struct__ |> Module.split() |> List.last()

    %{
      message: Exception.message(error),
      short_message: name,
      type: Macro.underscore(name),
      vars: %{},
      fields: [],
      path: Map.get(error, :path, [])
    }
  end

  defp protocol_error(error) do
    if ErrorProtocol.impl_for(error) do
      try do
        ErrorProtocol.to_error(error)
      rescue
        e ->
          Logger.warning("""
          Failed to transform error via protocol: #{inspect(e)}
          Original error: #{inspect(error)}
          """)

          fallback_error_response(error)
      end
    else
      handle_unimplemented_error(error)
    end
  end

  defp apply_error_handler({module, function, args}, error, context) do
    apply(module, function, [error, context | args])
  rescue
    e ->
      handler_failure(inspect(e), __STACKTRACE__, {module, function, args}, error)
  catch
    kind, reason ->
      handler_failure(
        "#{kind}: #{inspect(reason)}",
        __STACKTRACE__,
        {module, function, args},
        error
      )
  end

  # Error handlers are the application's hook for redacting or suppressing errors
  # before they reach the client, so a handler that fails must fail closed - never
  # fall back to the unredacted error it was supposed to sanitize.
  defp handler_failure(reason, stacktrace, handler, error) do
    uuid = Ash.UUID.generate()

    Logger.error("""
    Error handler failed, returning a generic error instead of the unhandled one.
    Error ID: #{uuid}
    Handler: #{inspect(handler)}
    Failure: #{reason}
    Original error: #{inspect(error)}
    #{Exception.format_stacktrace(stacktrace)}
    """)

    generic_internal_error(uuid, [])
  end

  defp generic_internal_error(uuid, path) do
    %{
      message: "Something went wrong. Unique error id: #{uuid}",
      short_message: "Internal error",
      type: "internal_error",
      vars: %{},
      fields: [],
      path: path,
      error_id: uuid
    }
  end

  defp maybe_policy_breakdown(
         %{} = transformed,
         %Ash.Error.Forbidden.Policy{} = source,
         %{profile: profile}
       )
       when not is_nil(profile) do
    if profile.show_policy_breakdowns?() do
      %{transformed | message: Ash.Error.Forbidden.Policy.report(source, help_text?: false)}
    else
      transformed
    end
  end

  defp maybe_policy_breakdown(transformed, _source, _runtime), do: transformed

  # An unknown input, filter/sort field or filter operator is what a client
  # built against an older manifest sends, so it carries the same hint as the
  # request errors ErrorBuilder flags.
  defp maybe_stale_client_hint(transformed, %struct{}, runtime)
       when struct in [
              Ash.Error.Invalid.NoSuchInput,
              Ash.Error.Query.NoSuchField,
              Ash.Error.Query.NoSuchFilterPredicate
            ] do
    case stale_client_hint(runtime) do
      nil -> transformed
      hint -> Map.update(transformed, :details, %{hint: hint}, &Map.put(&1, :hint, hint))
    end
  end

  defp maybe_stale_client_hint(transformed, _source, _runtime), do: transformed

  @doc false
  def stale_client_hint(%{profile: nil}), do: AshRpc.Profile.default_stale_client_hint()
  def stale_client_hint(%{profile: profile}), do: profile.stale_client_hint()

  defp profile_error_handler(%{profile: nil}, _domain), do: nil

  defp profile_error_handler(%{profile: profile}, domain) do
    case profile.error_handler(domain) do
      nil -> nil
      {m, f, a} -> {m, f, a}
      module when is_atom(module) -> {module, :handle_error, []}
    end
  end

  defp profile_show_raised_errors?(%{profile: nil}, _domain), do: false

  defp profile_show_raised_errors?(%{profile: profile}, domain),
    do: profile.show_raised_errors?(domain)

  defp handle_unimplemented_error(error) when is_exception(error) do
    uuid = Ash.UUID.generate()

    # Log the full error details for debugging (only visible server-side)
    Logger.warning("""
    Unhandled error in RPC (no protocol implementation).
    Error ID: #{uuid}
    Error type: #{inspect(error.__struct__)}
    Message: #{Exception.message(error)}

    To handle this error type, implement the AshRpc.Error protocol:

    defimpl AshRpc.Error, for: #{inspect(error.__struct__)} do
      def to_error(error) do
        %{
          message: error.message,
          short_message: "Error description",
          type: "error_type",
          vars: %{},
          fields: [],
          path: error.path || []
        }
      end
    end
    """)

    generic_internal_error(uuid, Map.get(error, :path, []))
  end

  defp handle_unimplemented_error(error) do
    uuid = Ash.UUID.generate()

    Logger.warning("""
    Unhandled non-exception error in RPC.
    Error ID: #{uuid}
    Error: #{inspect(error)}
    """)

    generic_internal_error(uuid, [])
  end

  # Ash.Error.to_error_class/1 wraps non-exceptions, so only exceptions reach an impl
  defp fallback_error_response(error) when is_exception(error) do
    %{
      message: "something went wrong",
      short_message: "Error",
      type: "error",
      vars: %{},
      fields: [],
      path: Map.get(error, :path, [])
    }
  end

  # Names an error's path, fields and vars.field for the client, then makes
  # every value JSON-safe (serialize_error/1).
  #
  # The path is walked through the decorated manifest from the action and
  # resource (AshRpc.ClientPath): each atom segment takes the client name of
  # the resource, action input or type it is on, overrides included; string
  # segments are reported as sent. With a non-empty path, fields are named
  # against the node the path ends at. With an empty path they are named
  # against the root: the action's argument overrides, then resource fields,
  # then the output formatter.
  defp format_error_field_names(error, resource, action, runtime) when is_map(error) do
    formatter = runtime.output_formatter
    resource_struct = resource && Map.get(runtime.resource_lookup, resource)

    {error, format_field} =
      case error do
        %{path: [_ | _] = path} ->
          {client_path, leaf} =
            ClientPath.resolve(path, ClientPath.root(runtime, resource, action), runtime)

          {%{error | path: client_path}, &ClientPath.name(leaf, &1, runtime)}

        _ ->
          {error, &format_error_field(&1, resource_struct, action, formatter)}
      end

    error
    |> format_fields_array(format_field)
    |> format_vars_field(format_field)
    |> serialize_error()
  end

  defp format_error_field_names(error, _resource, _action, _runtime), do: error

  # A string field name is one the client sent (an unknown input, filter or
  # sort name), so it is reported as sent. Atom names are internal and are
  # formatted for the client.
  defp format_error_field(field, _resource, _action, _formatter) when is_binary(field),
    do: field

  # An action argument is named the way the client sent it.
  defp format_error_field(field, %Ash.Info.Manifest.Resource{} = resource, action, formatter)
       when is_atom(field) and is_atom(action) and not is_nil(action),
       do: AshRpc.Introspection.format_input_name(resource, action, field, formatter)

  defp format_error_field(field, resource, _action, formatter),
    do: AshRpc.FieldFormatter.format_field_for_client(field, resource, formatter)

  defp format_fields_array(%{fields: fields} = error, format_field) when is_list(fields),
    do: %{error | fields: Enum.map(fields, format_field)}

  defp format_fields_array(error, _format_field), do: error

  defp format_vars_field(%{vars: vars} = error, format_field) when is_map(vars) do
    formatted_vars =
      Enum.into(vars, %{}, fn
        {:field, field} -> {:field, format_field.(field)}
        other -> other
      end)

    %{error | vars: formatted_vars}
  end

  defp format_vars_field(error, _format_field), do: error

  defp serialize_error(nil), do: nil

  defp serialize_error(value) when is_binary(value), do: value

  defp serialize_error(value) when is_number(value), do: value

  defp serialize_error(value) when is_boolean(value), do: value

  defp serialize_error(value) when is_atom(value), do: Atom.to_string(value)

  defp serialize_error(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&serialize_error/1)
  end

  defp serialize_error(value) when is_list(value) do
    cond do
      value == [] ->
        []

      Keyword.keyword?(value) ->
        Enum.into(value, %{}, fn {key, val} ->
          {to_string(key), serialize_error(val)}
        end)

      List.ascii_printable?(value) ->
        List.to_string(value)

      true ->
        Enum.map(value, &serialize_error/1)
    end
  end

  defp serialize_error(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize_error(%Date{} = value), do: Date.to_iso8601(value)
  defp serialize_error(%Time{} = value), do: Time.to_iso8601(value)
  defp serialize_error(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp serialize_error(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp serialize_error(%Ash.CiString{} = value), do: Ash.CiString.value(value)

  # Structs we have no serialization for are reduced to their module name.
  # Unwrapping them with Map.from_struct/1 would emit every field to the client,
  # defeating redaction the struct itself declares - `Ash.ForbiddenField`, for
  # instance, hides the `original_value` the actor is not allowed to see.
  defp serialize_error(%module{}) do
    Logger.warning("""
    Dropped a #{inspect(module)} value while serializing an RPC error.

    Structs without a known serialization are replaced with their module name so
    their fields are not disclosed to the client. Convert the value to a string,
    number, or plain map before putting it in an error's `vars` or `path`.
    """)

    opaque_term(module)
  end

  defp serialize_error(value) when is_map(value) do
    Enum.into(value, %{}, fn {key, val} ->
      {key, serialize_error(val)}
    end)
  end

  defp serialize_error(value) when is_pid(value), do: opaque_term(PID)
  defp serialize_error(value) when is_reference(value), do: opaque_term(Reference)
  defp serialize_error(value) when is_function(value), do: opaque_term(Function)

  defp serialize_error(value), do: value

  defp opaque_term(module), do: "##{inspect(module)}<>"
end
