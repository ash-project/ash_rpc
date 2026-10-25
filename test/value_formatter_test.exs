# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ValueFormatterTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Runtime, ValueFormatter}

  setup do
    %{runtime: Runtime.new(AshRpc.Test.Profile)}
  end

  test "output: mapped NewType fields use decorated overrides", %{runtime: rt} do
    value = %{word_count_1: 3, is_featured?: true}

    assert ValueFormatter.format(value, AshRpc.Test.PostStats, [], :output, rt) ==
             %{"wordCount1" => 3, "isFeatured" => true}
  end

  test "input: reverse overrides map client keys back", %{runtime: rt} do
    assert ValueFormatter.format(%{"wordCount1" => 3}, AshRpc.Test.PostStats, [], :input, rt) ==
             %{word_count_1: 3}
  end

  test "runtime formatter is used, not config", %{runtime: rt} do
    rt = %{rt | output_formatter: :pascal_case}

    assert %{"ThemeName" => "x"} =
             ValueFormatter.format(%{theme_name: "x"}, AshRpc.Test.PostSettings, [], :output, rt)
  end

  test "output: a custom type still :unknown at runtime passes through unchanged", %{runtime: rt} do
    # Decoration rejects undeclared map-like custom types on the wire, so the
    # runtime leaves such a value as produced: no stringified or formatted keys.
    value = %{point_x: 1, nested: %{inner_key: [%{deep_key: 2}]}}

    assert ValueFormatter.format(value, AshRpc.Test.DisabledPoint, [], :output, rt) == value
  end

  describe ":map_with_tag tag keys" do
    test "the tag key uses the member's decorated name, not re-formatted" do
      rt = Runtime.from_manifest(AshRpc.Test.ManifestBuilder.build(output_formatter: :snake_case))
      status = Ash.Info.Manifest.get_field(rt.resource_lookup, AshRpc.Test.Intake, :status).type
      value = %{active: %{status_type: "active", message: "on"}}

      assert ValueFormatter.format(value, status, [], :output, rt) ==
               %{"active" => %{"statusKind" => "active", "message" => "on"}}
    end
  end

  describe "strict input keys" do
    setup do
      rt = Runtime.from_manifest(AshRpc.Test.ManifestBuilder.manifest())
      meta = Ash.Info.Manifest.get_field(rt.resource_lookup, AshRpc.Test.Project, :metadata).type
      %{rt: rt, meta: meta}
    end

    test "an embedded resource resolves client names and throws every other casing", %{
      rt: rt,
      meta: meta
    } do
      assert ValueFormatter.format(%{"priorityScore" => 5}, meta, [], :input, rt) ==
               %{priority_score: 5}

      assert catch_throw(ValueFormatter.format(%{"priority_score" => 5}, meta, [], :input, rt)) ==
               {:unknown_nested_input, [{:unknown_input, "priority_score", []}]}
    end

    test "nested misses carry their path relative to the value", %{rt: rt, meta: meta} do
      value = %{"detail" => %{"Note" => "x"}, "category" => "c"}

      assert catch_throw(ValueFormatter.format(value, meta, [], :input, rt)) ==
               {:unknown_nested_input, [{:unknown_input, "Note", ["detail"]}]}
    end

    test "a type that was never decorated keeps its keys as sent", %{rt: rt} do
      value = %{"fooBar" => 1, "foo_bar" => 2}

      assert ValueFormatter.format(
               value,
               :map,
               [fields: [foo_bar: [type: :integer]]],
               :input,
               rt
             ) == value
    end

    test "declared custom-type input maps client names to atoms", %{rt: rt} do
      palette =
        Ash.Info.Manifest.get_field(rt.resource_lookup, AshRpc.Test.Project, :palette).type

      value = %{"primary" => "a", "secondary" => "b", "accentColor" => "c"}

      assert ValueFormatter.format(value, palette, [], :input, rt) ==
               %{primary: "a", secondary: "b", accent_color: "c"}

      assert catch_throw(ValueFormatter.format(%{"accent_color" => "c"}, palette, [], :input, rt)) ==
               {:unknown_nested_input, [{:unknown_input, "accent_color", []}]}
    end
  end

  describe "format_input/3" do
    alias Ash.Info.Manifest.Generator.TypeResolver
    alias Ash.Info.Manifest.Type

    setup do
      rt = Runtime.from_manifest(AshRpc.Test.ManifestBuilder.manifest())

      field_type = fn resource, field ->
        Ash.Info.Manifest.get_field(rt.resource_lookup, resource, field).type
      end

      %{
        rt: rt,
        field_type: field_type,
        intake: %Type{kind: :resource, resource_module: AshRpc.Test.Intake},
        widget: %Type{kind: :resource, resource_module: AshRpc.Test.Widget}
      }
    end

    test "formats a decorated typed map", %{rt: rt, field_type: ft} do
      assert ValueFormatter.format_input(
               %{"notificationEnabled" => true, "themeName" => "dark"},
               ft.(AshRpc.Test.Intake, :settings),
               rt
             ) == {:ok, %{notification_enabled: true, theme_name: "dark"}}
    end

    test "formats an embedded resource and an array of them", %{rt: rt, field_type: ft} do
      assert ValueFormatter.format_input(
               %{"displayName" => "Ada", "bioText1" => "b"},
               ft.(AshRpc.Test.Intake, :profile),
               rt
             ) == {:ok, %{display_name: "Ada", bio_text_1: "b"}}

      assert ValueFormatter.format_input(
               [%{"displayName" => "one"}, %{"isPublic" => true}],
               ft.(AshRpc.Test.Intake, :history),
               rt
             ) == {:ok, [%{display_name: "one"}, %{is_public?: true}]}
    end

    test "formats a union member under its client key", %{rt: rt, widget: widget} do
      assert {:ok, %{attachments: [%{filename: "a", mime_type: "x"}]}} =
               ValueFormatter.format_input(
                 %{"attachments" => [%{"file" => %{"filename" => "a", "mimeType" => "x"}}]},
                 widget,
                 rt
               )
    end

    test "a miss directly in the value has an empty path", %{rt: rt, field_type: ft} do
      assert ValueFormatter.format_input(
               %{"theme_name" => "dark"},
               ft.(AshRpc.Test.Intake, :settings),
               rt
             ) == {:error, [{:unknown_input, "theme_name", []}]}
    end

    test "deeper misses carry paths relative to the value", %{
      rt: rt,
      intake: intake,
      widget: widget
    } do
      assert ValueFormatter.format_input(
               %{"history" => [%{"displayName" => "one"}, %{"is_public" => true}]},
               intake,
               rt
             ) == {:error, [{:unknown_input, "is_public", ["history", 1]}]}

      assert ValueFormatter.format_input(
               %{"attachments" => [%{"file" => %{"filename" => "a", "mime_type" => "x"}}]},
               widget,
               rt
             ) == {:error, [{:unknown_input, "mime_type", ["attachments", 0, "file"]}]}
    end

    test "every miss is returned together, in input order", %{rt: rt, intake: intake} do
      assert ValueFormatter.format_input(
               %{
                 "bogus" => 1,
                 "profile" => %{"display_name" => "Ada"},
                 "settings" => %{"theme_name" => "dark"}
               },
               intake,
               rt
             ) ==
               {:error,
                [
                  {:unknown_input, "bogus", []},
                  {:unknown_input, "display_name", ["profile"]},
                  {:unknown_input, "theme_name", ["settings"]}
                ]}
    end

    test "undecorated nodes and unconstrained maps pass through", %{rt: rt} do
      value = %{"fooBar" => 1, "foo_bar" => 2}

      assert ValueFormatter.format_input(
               value,
               TypeResolver.resolve(:map, fields: [foo_bar: [type: :integer]]),
               rt
             ) == {:ok, value}

      loose = %{"anyKey" => %{"nested_key" => 1}}

      assert ValueFormatter.format_input(loose, TypeResolver.resolve(:map, []), rt) ==
               {:ok, loose}
    end

    test "a malformed union value is an error, not a throw", %{rt: rt, widget: widget} do
      assert ValueFormatter.format_input(%{"attachments" => ["not a map"]}, widget, rt) ==
               {:error, [{:invalid_union_input, :not_a_map}]}

      assert {:error, [{:invalid_union_input, :multiple_member_keys, _, _}]} =
               ValueFormatter.format_input(
                 %{"attachments" => [%{"file" => %{}, "image" => %{}}]},
                 widget,
                 rt
               )
    end
  end
end
