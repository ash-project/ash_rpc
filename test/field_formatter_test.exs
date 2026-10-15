# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.FieldFormatterTest do
  use ExUnit.Case, async: true

  alias Ash.Info.Manifest
  alias AshRpc.FieldFormatter

  @resource %Manifest.Resource{
    module: AshRpc.Test.Author,
    custom: %{
      ash_rpc: %{
        field_names: %{name: "name", is_active?: "isActive"},
        field_name_overrides: %{is_active?: "isActive"},
        reverse_field_name_overrides: %{"isActive" => :is_active?},
        argument_name_overrides: %{},
        reverse_argument_name_overrides: %{},
        authorize_bulk_strategy: :filter
      }
    }
  }

  @type_struct %Manifest.Type{
    module: AshRpc.Test.PostStats,
    custom: %{
      ash_rpc: %{
        field_name_overrides: %{word_count_1: "wordCount1"},
        reverse_field_name_overrides: %{"wordCount1" => :word_count_1}
      }
    }
  }

  test "overrides win over the formatter for decorated resources" do
    assert FieldFormatter.format_field_for_client(:is_active?, @resource, :camel_case) ==
             "isActive"

    assert FieldFormatter.format_field_for_client(:is_active?, @resource, :snake_case) ==
             "isActive"
  end

  test "non-overridden resource fields use the given formatter" do
    assert FieldFormatter.format_field_for_client(:user_name, @resource, :pascal_case) ==
             "UserName"
  end

  test "type overrides are honoured" do
    assert FieldFormatter.format_field_for_client(:word_count_1, @type_struct, :camel_case) ==
             "wordCount1"

    assert FieldFormatter.format_field_for_client(:other_field, @type_struct, :camel_case) ==
             "otherField"
  end

  test "nil and module atoms fall back to the formatter (no reflection)" do
    assert FieldFormatter.format_field_for_client(:user_name, nil, :camel_case) == "userName"

    assert FieldFormatter.format_field_for_client(:user_name, AshRpc.Test.Author, :camel_case) ==
             "userName"
  end

  test "format_sort_string/2 keeps every modifier and parses field names" do
    assert FieldFormatter.format_sort_string(
             "++viewCount,--title,+id,-isActive,title",
             :camel_case
           ) ==
             "++view_count,--title,+id,-is_active,title"

    assert FieldFormatter.format_sort_string(["-viewCount", "title"], :camel_case) ==
             "-view_count,title"

    assert FieldFormatter.format_sort_string(nil, :camel_case) == nil
  end

  test "parse_input_field/2 returns an existing atom or the parsed string" do
    assert FieldFormatter.parse_input_field("viewCount", :camel_case) == :view_count
    assert FieldFormatter.parse_input_field("noSuchFieldXyz", :camel_case) == "no_such_field_xyz"
  end

  test "Case conversions" do
    assert AshRpc.Case.snake_to_camel_case("user_name") == "userName"
    assert AshRpc.Case.snake_to_pascal_case("user_name") == "UserName"
    assert AshRpc.Case.camel_to_snake_case("userName") == "user_name"
    assert AshRpc.Case.pascal_to_snake_case("UserName") == "user_name"
  end

  describe "format_field_name/2" do
    test "single-word and empty names under each built-in formatter" do
      assert FieldFormatter.format_field_name(:name, :camel_case) == "name"
      assert FieldFormatter.format_field_name(:email, :pascal_case) == "Email"
      assert FieldFormatter.format_field_name(:title, :snake_case) == "title"

      for formatter <- [:camel_case, :pascal_case, :snake_case] do
        assert FieldFormatter.format_field_name("", formatter) == ""
      end
    end

    test "a {module, function} formatter is called with the field name" do
      assert FieldFormatter.format_field_name(:author_name, {__MODULE__, :prefix_custom}) ==
               "custom_author_name"

      assert FieldFormatter.format_field_name("email", {__MODULE__, :upcase}) == "EMAIL"
    end

    test "a {module, function, args} formatter gets the extra args after the field name" do
      assert FieldFormatter.format_field_name(:author_name, {__MODULE__, :suffix, ["test"]}) ==
               "author_name_test"

      assert FieldFormatter.format_field_name(
               "email",
               {__MODULE__, :wrap, ["prefix", "suffix"]}
             ) == "prefix_email_suffix"
    end

    test "an unsupported formatter raises ArgumentError" do
      # Built at runtime so the type checker sees `atom()` rather than an
      # invalid formatter literal.
      invalid = String.to_atom("invalid_formatter")

      assert_raise ArgumentError, "Unsupported formatter: :invalid_formatter", fn ->
        FieldFormatter.format_field_name(:author_name, invalid)
      end
    end

    test "an exception raised by a custom formatter propagates" do
      assert_raise RuntimeError, "custom formatter error", fn ->
        FieldFormatter.format_field_name(:author_name, {__MODULE__, :raise_error})
      end
    end
  end

  describe "parse_input_field/2" do
    test "parses each built-in casing to the existing atom" do
      assert FieldFormatter.parse_input_field("emailAddress", :camel_case) == :email_address
      assert FieldFormatter.parse_input_field("EmailAddress", :pascal_case) == :email_address
      assert FieldFormatter.parse_input_field("email_address", :snake_case) == :email_address
      assert FieldFormatter.parse_input_field("Email", :pascal_case) == :email
    end

    test "an empty name parses to the empty atom under each built-in formatter" do
      for formatter <- [:camel_case, :pascal_case, :snake_case] do
        assert FieldFormatter.parse_input_field("", formatter) == :""
      end
    end

    test "a {module, function} parser's atom result is returned as-is" do
      assert FieldFormatter.parse_input_field("input_author_name", {__MODULE__, :strip_input}) ==
               :author_name

      assert FieldFormatter.parse_input_field("input_email", {__MODULE__, :strip_input}) ==
               :email
    end

    test "an unsupported formatter raises ArgumentError" do
      invalid = String.to_atom("invalid_formatter")

      assert_raise ArgumentError, "Unsupported formatter: :invalid_formatter", fn ->
        FieldFormatter.parse_input_field("authorName", invalid)
      end
    end
  end

  describe "format_fields/2" do
    @fields %{author_name: "Ada", email_address: "ada@example.com", created_at: "2023-01-01"}

    test "formats every key with each built-in formatter" do
      assert FieldFormatter.format_fields(@fields, :camel_case) == %{
               "authorName" => "Ada",
               "emailAddress" => "ada@example.com",
               "createdAt" => "2023-01-01"
             }

      assert FieldFormatter.format_fields(@fields, :pascal_case) == %{
               "AuthorName" => "Ada",
               "EmailAddress" => "ada@example.com",
               "CreatedAt" => "2023-01-01"
             }

      assert FieldFormatter.format_fields(@fields, :snake_case) == %{
               "author_name" => "Ada",
               "email_address" => "ada@example.com",
               "created_at" => "2023-01-01"
             }
    end

    test "formats every key with custom formatters" do
      fields = %{author_name: "Ada", email: "ada@example.com"}

      assert FieldFormatter.format_fields(fields, {__MODULE__, :prefix_custom}) == %{
               "custom_author_name" => "Ada",
               "custom_email" => "ada@example.com"
             }

      assert FieldFormatter.format_fields(fields, {__MODULE__, :suffix, ["test"]}) == %{
               "author_name_test" => "Ada",
               "email_test" => "ada@example.com"
             }
    end

    test "string keys are formatted and an empty map stays empty" do
      assert FieldFormatter.format_fields(
               %{"author_name" => "Ada", "email_address" => "ada@example.com"},
               :camel_case
             ) == %{"authorName" => "Ada", "emailAddress" => "ada@example.com"}

      assert FieldFormatter.format_fields(%{}, :camel_case) == %{}
      assert FieldFormatter.format_fields(%{}, {__MODULE__, :prefix_custom}) == %{}
    end

    test "nil values are kept" do
      assert FieldFormatter.format_fields(
               %{author_name: nil, email_address: "ada@example.com"},
               :camel_case
             ) == %{"authorName" => nil, "emailAddress" => "ada@example.com"}
    end

    test "only top-level keys are formatted; nested values are left untouched" do
      fields = %{
        user_info: %{nested_field: "value", another_nested: [1, 2, 3]},
        settings: %{enabled: true}
      }

      assert FieldFormatter.format_fields(fields, :camel_case) == %{
               "userInfo" => %{nested_field: "value", another_nested: [1, 2, 3]},
               "settings" => %{enabled: true}
             }
    end

    test "numeric and boolean keys become strings" do
      assert FieldFormatter.format_fields(%{123 => "value", true => "another"}, :snake_case) ==
               %{"123" => "value", "true" => "another"}
    end
  end

  describe "parse_input_fields/2" do
    @parsed %{author_name: "Ada", email_address: "ada@example.com", created_at: "2023-01-01"}

    test "parses every key from each built-in casing" do
      assert FieldFormatter.parse_input_fields(
               %{
                 "authorName" => "Ada",
                 "emailAddress" => "ada@example.com",
                 "createdAt" => "2023-01-01"
               },
               :camel_case
             ) == @parsed

      assert FieldFormatter.parse_input_fields(
               %{
                 "AuthorName" => "Ada",
                 "EmailAddress" => "ada@example.com",
                 "CreatedAt" => "2023-01-01"
               },
               :pascal_case
             ) == @parsed

      assert FieldFormatter.parse_input_fields(
               %{
                 "author_name" => "Ada",
                 "email_address" => "ada@example.com",
                 "created_at" => "2023-01-01"
               },
               :snake_case
             ) == @parsed
    end

    test "parses every key with a custom parser, and an empty map stays empty" do
      assert FieldFormatter.parse_input_fields(
               %{"input_author_name" => "Ada", "input_email" => "ada@example.com"},
               {__MODULE__, :strip_input}
             ) == %{author_name: "Ada", email: "ada@example.com"}

      assert FieldFormatter.parse_input_fields(%{}, :camel_case) == %{}
      assert FieldFormatter.parse_input_fields(%{}, {__MODULE__, :strip_input}) == %{}
    end

    test "nested map keys are parsed while nil, list and scalar values are kept" do
      assert FieldFormatter.parse_input_fields(
               %{
                 "authorName" => %{"nested" => "value"},
                 "emailAddress" => [1, 2, 3],
                 "createdAt" => nil
               },
               :camel_case
             ) == %{author_name: %{nested: "value"}, email_address: [1, 2, 3], created_at: nil}
    end
  end

  def prefix_custom(field), do: "custom_#{field}"
  def upcase(field), do: field |> to_string() |> String.upcase()
  def suffix(field, suffix), do: "#{field}_#{suffix}"
  def wrap(field, prefix, suffix), do: "#{prefix}_#{field}_#{suffix}"
  def raise_error(_field), do: raise("custom formatter error")

  def strip_input(field) do
    field |> to_string() |> String.replace_leading("input_", "") |> String.to_existing_atom()
  end

  describe "atom safety" do
    test "resolves an existing field name to its atom" do
      # :view_count exists as an atom because AshRpc.Test.Post has that attribute.
      _ = :view_count
      assert FieldFormatter.resolve_field_name("viewCount", :camel_case) == :view_count
    end

    test "passes atoms through unchanged" do
      assert FieldFormatter.resolve_field_name(:already_atom, :camel_case) == :already_atom
    end

    test "never mints a new atom for an unknown field name" do
      unique = "atom_bomb_field_name_#{System.unique_integer([:positive])}_xyz"
      camel = "atomBombFieldName#{System.unique_integer([:positive])}Xyz"

      refute atom_exists?(unique)

      result = FieldFormatter.resolve_field_name(camel, :camel_case)

      # Falls back to the formatted string, which field selection rejects as
      # an unknown field rather than atomizing.
      assert is_binary(result)
      refute atom_exists?(result)
    end

    test "does not mint atoms for a batch of unique field names" do
      names = for i <- 1..1_000, do: "atomBombBatch#{i}_#{System.unique_integer([:positive])}"

      Enum.each(names, fn name ->
        result = FieldFormatter.resolve_field_name(name, :camel_case)
        assert is_binary(result)
        refute atom_exists?(result)
      end)
    end

    test "does not raise on field names longer than the 255-char atom limit" do
      long = String.duplicate("a", 300)

      result = FieldFormatter.resolve_field_name(long, :camel_case)
      assert is_binary(result)
    end
  end

  describe "atom safety in typed map field selection" do
    # :stats_summary returns AshRpc.Test.PostStats, a NewType map whose client
    # names come from the mapping source's type_field_names/1, so selection on it
    # goes through the field-constrained type path rather than resource fields.
    defp select_stats_summary_fields(fields) do
      AshRpc.RequestedFieldsProcessor.process(
        AshRpc.Runtime.new(AshRpc.Test.Profile),
        AshRpc.Test.Post,
        :stats_summary,
        fields
      )
    end

    test "an unknown field name is rejected without minting an atom" do
      name = "zzAtomBombStat#{System.unique_integer([:positive])}"

      refute atom_exists?(Macro.underscore(name))

      assert {:error, {:unknown_field, unknown, "field_constrained_type", []}} =
               select_stats_summary_fields([name])

      assert is_binary(unknown)
      refute atom_exists?(unknown)
    end

    test "a batch of unique unknown field names mints no atoms" do
      names = for i <- 1..500, do: "zzAtomBombBatch#{i}_#{System.unique_integer([:positive])}"

      Enum.each(names, fn name ->
        assert {:error, {:unknown_field, unknown, _, _}} = select_stats_summary_fields([name])
        assert is_binary(unknown)
        refute atom_exists?(Macro.underscore(name))
      end)
    end

    test "valid field names still resolve, including mapped ones" do
      assert {:ok, {_select, _load, template}} =
               select_stats_summary_fields(["wordCount1", "isFeatured"])

      assert [:word_count_1, :is_featured?] = template
    end
  end

  defp atom_exists?(name) when is_binary(name) do
    _ = String.to_existing_atom(name)
    true
  rescue
    ArgumentError -> false
  end
end
