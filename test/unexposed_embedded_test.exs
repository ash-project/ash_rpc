# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.UnexposedEmbeddedTest do
  use ExUnit.Case, async: true

  alias AshRpc.Manifest.Custom
  alias AshRpc.Test.{ManifestBuilder, QuoteBlock, Widget}

  # QuoteBlock is an embedded resource the test mapping source does not
  # expose (and whose field_names/argument_names raise), reached through
  # Widget.caption (attribute) and Widget.aside (union member :quote).
  @profile AshRpc.Test.Profile

  defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

  defp quote_block do
    ManifestBuilder.manifest() |> AshRpc.Manifest.resource_lookup() |> Map.fetch!(QuoteBlock)
  end

  describe "decoration" do
    test "an unexposed embedded resource gets formatter-only client names" do
      res = quote_block()

      assert Custom.client_field_names(res) == %{
               "text" => :text,
               "attributedTo" => :attributed_to,
               "wordCount" => :word_count
             }

      assert Custom.field_name_overrides(res) == %{}
    end

    test "it is decorated but not exposed" do
      refute Custom.exposed?(quote_block())
    end
  end

  describe "run_action through an unexposed embedded resource" do
    test "attribute input and field selection use the formatter names" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_widget",
                 "input" => %{"caption" => %{"text" => "Hi", "attributedTo" => "Ada"}},
                 "fields" => ["id", %{"caption" => ["text", "attributedTo"]}]
               })

      assert data["caption"] == %{"text" => "Hi", "attributedTo" => "Ada"}
      assert %QuoteBlock{attributed_to: "Ada"} = Ash.get!(Widget, data["id"]).caption
    end

    test "union member input and field selection use the formatter names" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_widget",
                 "input" => %{"aside" => %{"quote" => %{"text" => "Hi", "wordCount" => 1}}},
                 "fields" => ["id", %{"aside" => [%{"quote" => ["text", "wordCount"]}]}]
               })

      assert data["aside"] == %{"quote" => %{"text" => "Hi", "wordCount" => 1}}
    end

    test "nested input keys are strict: a non-client name is unknown_input" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "create_widget",
                 "input" => %{"caption" => %{"text" => "Hi", "attributed_to" => "Ada"}},
                 "fields" => ["id"]
               })

      assert error["type"] == "unknown_input"
      assert error["fields"] == ["attributed_to"]
      assert error["path"] == ["caption"]
    end

    test "an unknown field selected through it is unknown_field" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{"action" => "list_widgets", "fields" => [%{"caption" => ["attributed_to"]}]})

      assert error["type"] == "unknown_field"
    end
  end

  describe "domain resources keep strict exposure" do
    test "a relationship to an unexposed domain resource stays unknown_field" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{"action" => "list_posts", "fields" => ["id", %{"secret" => ["id"]}]})

      assert error["type"] == "unknown_field"
    end

    test "an unexposed domain resource is not decorated" do
      lookup = AshRpc.Manifest.resource_lookup(ManifestBuilder.manifest())
      refute Custom.exposed?(Map.get(lookup, AshRpc.Test.Secret))
      assert Custom.client_field_names(Map.get(lookup, AshRpc.Test.Secret)) == %{}
    end
  end
end
