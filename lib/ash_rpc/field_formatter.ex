# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldFormatter do
  @moduledoc """
  Formats internal field names for clients. Client names are resolved by
  `AshRpc.ClientNames`, never parsed.

  Supports built-in formatters and custom formatter functions.
  """

  import AshRpc.Case

  alias Ash.Info.Manifest
  alias AshRpc.Manifest.Custom

  @doc """
  Formats a field name for client output, applying the client-name overrides
  carried by a decorated `Ash.Info.Manifest.Resource` or `Ash.Info.Manifest.Type`.

  ## Examples

      iex> AshRpc.FieldFormatter.format_field_for_client(:user_name, nil, :camel_case)
      "userName"

      iex> AshRpc.FieldFormatter.format_field_for_client("already_string", nil, :camel_case)
      "alreadyString"

  When the struct carries an override (e.g., `:is_active?` → `"isActive"`), the
  override is used directly WITHOUT additional formatting. Module atoms and
  `nil` fall back to the formatter.
  """
  def format_field_for_client(field, resource_or_type \\ nil, formatter)

  def format_field_for_client(field, %Manifest.Resource{} = resource, formatter)
      when is_atom(field) do
    Custom.field_name_override(resource, field) || format_field_name(field, formatter)
  end

  def format_field_for_client(field, %Manifest.Type{} = type, formatter) when is_atom(field) do
    Map.get(Custom.type_field_name_overrides(type), field) || format_field_name(field, formatter)
  end

  def format_field_for_client(field, _other, formatter) when is_atom(field) or is_binary(field),
    do: format_field_name(field, formatter)

  def format_field_for_client(other, _resource, _formatter), do: other

  @doc """
  Formats a map of fields, converting all keys using the specified formatter.

  ## Examples

      iex> AshRpc.FieldFormatter.format_fields(%{user_name: "John", user_email: "john@example.com"}, :camel_case)
      %{"userName" => "John", "userEmail" => "john@example.com"}
  """
  def format_fields(fields, formatter) when is_map(fields) do
    Enum.into(fields, %{}, fn {key, value} ->
      formatted_key = format_field_name(key, formatter)
      {formatted_key, value}
    end)
  end

  @doc """
  Recursively formats all keys in a nested structure for client consumption.

  Walks maps and lists, converting every key with the given formatter. Structs
  and primitives are returned untouched, and non-atom/non-binary keys are left
  as-is.

  Used for any payload that is handed to the client without going through a
  type-driven formatter. RPC responses and an extension's own payloads (for
  example error bodies it builds itself) can both use it, so their field names
  agree.

  ## Examples

      iex> AshRpc.FieldFormatter.format_output_field_names(%{short_message: "x"}, :camel_case)
      %{"shortMessage" => "x"}

      iex> AshRpc.FieldFormatter.format_output_field_names([%{user_name: "a"}], :camel_case)
      [%{"userName" => "a"}]
  """
  def format_output_field_names(data, formatter) do
    case data do
      map when is_map(map) and not is_struct(map) ->
        Enum.into(map, %{}, fn {key, value} ->
          formatted_key =
            case key do
              key when is_atom(key) or is_binary(key) -> format_field_name(key, formatter)
              other -> other
            end

          {formatted_key, format_output_field_names(value, formatter)}
        end)

      list when is_list(list) ->
        Enum.map(list, &format_output_field_names(&1, formatter))

      other ->
        other
    end
  end

  @doc """
  Formats a field name using the configured formatter.

  ## Examples

      iex> AshRpc.FieldFormatter.format_field_name(:user_name, :camel_case)
      "userName"

      iex> AshRpc.FieldFormatter.format_field_name(:user_name, :snake_case)
      "user_name"

      iex> AshRpc.FieldFormatter.format_field_name("user_name", :pascal_case)
      "UserName"
  """
  def format_field_name(field_name, formatter) do
    string_field = to_string(field_name)

    case formatter do
      :camel_case ->
        if is_camel_case?(string_field) do
          string_field
        else
          snake_to_camel_case(string_field)
        end

      :pascal_case ->
        if is_pascal_case?(string_field) do
          string_field
        else
          snake_to_pascal_case(string_field)
        end

      :snake_case ->
        if is_snake_case?(string_field) do
          string_field
        else
          camel_to_snake_case(string_field)
        end

      {module, function} ->
        apply(module, function, [field_name])

      {module, function, extra_args} ->
        apply(module, function, [field_name | extra_args])

      _ ->
        raise ArgumentError, "Unsupported formatter: #{inspect(formatter)}"
    end
  end

  defp is_camel_case?(string) do
    # camelCase: starts with lowercase, no underscores, has at least one uppercase
    String.match?(string, ~r/^[a-z][a-zA-Z0-9]*$/) && String.match?(string, ~r/[A-Z]/)
  end

  defp is_pascal_case?(string) do
    # PascalCase: starts with uppercase, no underscores
    String.match?(string, ~r/^[A-Z][a-zA-Z0-9]*$/)
  end

  defp is_snake_case?(string) do
    # snake_case: lowercase with underscores, no uppercase
    String.match?(string, ~r/^[a-z][a-z0-9_]*$/) && String.contains?(string, "_")
  end
end
