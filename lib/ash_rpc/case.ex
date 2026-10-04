# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Case do
  @moduledoc false
  def snake_to_pascal_case(snake) when is_atom(snake) do
    snake
    |> Atom.to_string()
    |> snake_to_pascal_case()
  end

  def snake_to_pascal_case(snake) when is_binary(snake) do
    Macro.camelize(snake)
  end

  def snake_to_camel_case(snake) when is_atom(snake) do
    snake
    |> Atom.to_string()
    |> snake_to_camel_case()
  end

  def snake_to_camel_case(snake) when is_binary(snake) do
    case Macro.camelize(snake) do
      <<first::utf8, rest::binary>> -> String.downcase(<<first::utf8>>) <> rest
      "" -> ""
    end
  end

  def camel_to_snake_case(camel) when is_binary(camel) do
    Macro.underscore(camel)
  end

  def camel_to_snake_case(camel) when is_atom(camel) do
    camel
    |> Atom.to_string()
    |> camel_to_snake_case()
  end

  def pascal_to_snake_case(pascal) when is_atom(pascal) do
    pascal
    |> Atom.to_string()
    |> pascal_to_snake_case()
  end

  def pascal_to_snake_case(pascal) when is_binary(pascal) do
    Macro.underscore(pascal)
  end
end
