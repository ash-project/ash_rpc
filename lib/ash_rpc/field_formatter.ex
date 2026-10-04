# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldFormatter do
  @moduledoc """
  Handles field name formatting for input parameters and output fields.

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
  Parses input field names from client format to internal format.

  This is used for converting incoming client field names to the internal
  Elixir atom keys that Ash expects.

  ## Examples

      iex> AshRpc.FieldFormatter.parse_input_field("userName", :camel_case)
      :user_name
  """
  def parse_input_field(field_name, formatter)
      when is_binary(field_name) or is_atom(field_name) do
    case parse_field_name(field_name, formatter) do
      name when is_binary(name) ->
        try do
          String.to_existing_atom(name)
        rescue
          ArgumentError -> name
        end

      name ->
        name
    end
  end

  @doc """
  Resolves a field name to its existing atom, applying the formatter for case conversion.

  Atoms are passed through unchanged. Every valid string field name corresponds to
  an atom that already exists (resource attributes, relationships, calculations, and
  aggregates are all defined at compile time), so a string resolves to an existing
  atom when one is available and otherwise returns the formatted string unchanged.
  Downstream field selection compares the result against the known field atoms, so an
  unresolved name simply fails as an unknown field.

  This deliberately never calls `String.to_atom/1`: client-supplied field names
  are attacker-controllable, and minting a fresh atom per name would allow atom
  table exhaustion (a node-wide denial of service).

  ## Examples

      iex> AshRpc.FieldFormatter.resolve_field_name("userName", :camel_case)
      :user_name

      iex> AshRpc.FieldFormatter.resolve_field_name(:user_name, :camel_case)
      :user_name
  """
  def resolve_field_name(field_name, _formatter) when is_atom(field_name), do: field_name

  def resolve_field_name(field_name, formatter) when is_binary(field_name) do
    parse_input_field(field_name, formatter)
  end

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
  Parses a map of input fields, converting all keys from client format to internal format.

  Recursively processes nested maps and arrays to ensure all field names are properly formatted.
  This is essential for union types and embedded resources that contain nested field structures.

  ## Examples

      iex> AshRpc.FieldFormatter.parse_input_fields(%{"userName" => "John", "userEmail" => "john@example.com"}, :camel_case)
      %{user_name: "John", user_email: "john@example.com"}

      iex> AshRpc.FieldFormatter.parse_input_fields(%{"attachments" => [%{"mimeType" => "pdf", "attachmentType" => "file"}]}, :camel_case)
      %{attachments: [%{mime_type: "pdf", attachment_type: "file"}]}
  """
  def parse_input_fields(fields, formatter) when is_map(fields) do
    Enum.into(fields, %{}, fn {key, value} ->
      internal_key = parse_input_field(key, formatter)
      formatted_value = parse_input_value(value, formatter)
      {internal_key, formatted_value}
    end)
  end

  @doc """
  Recursively parses input values, handling nested structures.

  This function ensures that all nested maps and arrays containing maps
  have their field names properly formatted according to the formatter.

  Only handles JSON-decoded data (maps, lists, primitives) - no structs.
  """
  def parse_input_value(value, formatter) do
    case value do
      map when is_map(map) ->
        parse_input_fields(map, formatter)

      list when is_list(list) ->
        Enum.map(list, fn item -> parse_input_value(item, formatter) end)

      primitive ->
        primitive
    end
  end

  @doc """
  Recursively formats all keys in a nested structure for client consumption.

  Walks maps and lists, converting every key with the given formatter. Structs
  and primitives are returned untouched, and non-atom/non-binary keys are left
  as-is.

  Used for any payload that is handed to the client without going through a
  type-driven formatter — RPC responses and typed controller error bodies both
  rely on this so their field names agree.

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

  @doc """
  Formats a sort string by converting field names from client format to internal format.

  Handles Ash.Query.sort_input format:
  - "name" or "+name" (ascending)
  - "++name" (ascending with nils first)
  - "-name" (descending)
  - "--name" (descending with nils last)
  - "-name,++title" (multiple fields with different modifiers)

  Preserves sort modifiers while converting field names using the input formatter.

  ## Examples

      iex> AshRpc.FieldFormatter.format_sort_string("--startDate,++insertedAt", :camel_case)
      "--start_date,++inserted_at"

      iex> AshRpc.FieldFormatter.format_sort_string("-userName", :camel_case)
      "-user_name"

      iex> AshRpc.FieldFormatter.format_sort_string(nil, :camel_case)
      nil
  """
  def format_sort_string(nil, _formatter), do: nil

  def format_sort_string(sort_list, formatter) when is_list(sort_list) do
    sort_list
    |> Enum.map_join(",", &format_single_sort_field(&1, formatter))
  end

  def format_sort_string(sort_string, formatter) when is_binary(sort_string) do
    sort_string
    |> String.split(",")
    |> Enum.map_join(",", &format_single_sort_field(&1, formatter))
  end

  defp format_single_sort_field(field_with_modifier, formatter) do
    {modifier, field_name} =
      case field_with_modifier do
        "++" <> field_name -> {"++", field_name}
        "--" <> field_name -> {"--", field_name}
        "+" <> field_name -> {"+", field_name}
        "-" <> field_name -> {"-", field_name}
        field_name -> {"", field_name}
      end

    modifier <> to_string(parse_input_field(field_name, formatter))
  end

  # Private helper for parsing field names from client format to internal format
  defp parse_field_name(field_name, formatter) do
    case formatter do
      :camel_case ->
        field_name |> to_string() |> camel_to_snake_case()

      :pascal_case ->
        field_name |> to_string() |> pascal_to_snake_case()

      :snake_case ->
        field_name |> to_string()

      {module, function} ->
        apply(module, function, [field_name])

      {module, function, extra_args} ->
        apply(module, function, [field_name | extra_args])

      _ ->
        raise ArgumentError, "Unsupported formatter: #{inspect(formatter)}"
    end
  end
end
