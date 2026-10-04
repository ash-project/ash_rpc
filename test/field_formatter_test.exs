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
end
