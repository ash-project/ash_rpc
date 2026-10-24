# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ComplexInputTest do
  # Complex-type input over the wire: most tests read the stored value back
  # with Ash and compare it against internal (Elixir) names, so they prove the
  # client → internal input translation rather than the output formatting.
  use ExUnit.Case, async: true

  alias AshRpc.Test.{Author, Intake, IntakeProfile, IntakeSection, IntakeStatus, Widget}

  @profile AshRpc.Test.Profile

  defp ctx, do: %AshRpc.Context{}
  defp run(params), do: AshRpc.run_action(@profile, ctx(), params)
  defp validate(params), do: AshRpc.validate_action(@profile, ctx(), params)

  defp create_intake!(input) do
    assert %{"success" => true, "data" => %{"id" => id}} =
             run(%{
               "action" => "create_intake",
               "input" => Map.put_new(input, "userName", "ada"),
               "fields" => ["id"]
             })

    Ash.get!(Intake, id)
  end

  describe "typed and NewType map attributes" do
    test "a typed-map attribute stores its fields under internal names" do
      intake =
        create_intake!(%{"settings" => %{"notificationEnabled" => true, "themeName" => "dark"}})

      assert intake.settings == %{notification_enabled: true, theme_name: "dark"}
    end

    test "a NewType map with field overrides maps client keys back to internal names" do
      intake =
        create_intake!(%{
          "stats" => %{
            "totalCount1" => 100,
            "isComplete" => true,
            "lastUpdatedAt" => "2025-01-15T10:30:00Z"
          }
        })

      assert intake.stats == %{
               total_count_1: 100,
               is_complete?: true,
               last_updated_at: ~U[2025-01-15 10:30:00Z]
             }
    end

    test "a NewType map nested inside a NewType map maps its own overrides" do
      intake =
        create_intake!(%{
          "deep" => %{
            "displayName" => "Main",
            "isEnabled1" => true,
            "inner" => %{"maxRetries1" => 5, "isCached" => true}
          }
        })

      assert intake.deep == %{
               display_name: "Main",
               is_enabled_1?: true,
               inner: %{max_retries_1: 5, is_cached?: true}
             }
    end

    test "a keyword NewType maps overridden keys" do
      intake =
        create_intake!(%{
          "preferences" => %{"theme1" => "ocean", "fontSize" => 14, "isDarkMode" => true}
        })

      assert Enum.sort(intake.preferences) ==
               Enum.sort(theme_1: "ocean", font_size: 14, is_dark_mode?: true)
    end

    test "a tuple NewType maps overridden keys into tuple positions" do
      intake =
        create_intake!(%{
          "location" => %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}
        })

      assert intake.location == {37.7749, -122.4194, true}
    end

    test "an update maps NewType and attribute overrides the same way as a create" do
      intake = create_intake!(%{})

      assert %{"success" => true} =
               run(%{
                 "action" => "update_intake",
                 "identity" => intake.id,
                 "input" => %{
                   "isActive" => true,
                   "version1" => 2,
                   "stats" => %{"totalCount1" => 7, "isComplete" => false}
                 },
                 "fields" => ["id"]
               })

      updated = Ash.get!(Intake, intake.id)
      assert updated.is_active? == true
      assert updated.version_1 == 2
      assert updated.stats == %{total_count_1: 7, is_complete?: false}
    end
  end

  describe "embedded resource input" do
    test "an embedded resource maps its field overrides" do
      intake =
        create_intake!(%{
          "profile" => %{"displayName" => "Ada", "bioText1" => "bio", "isPublic" => false}
        })

      assert %IntakeProfile{display_name: "Ada", bio_text_1: "bio", is_public?: false} =
               intake.profile
    end

    test "an array of embedded resources maps each item" do
      intake =
        create_intake!(%{
          "history" => [
            %{"displayName" => "one", "bioText1" => "a", "isPublic" => true},
            %{"displayName" => "two", "isPublic" => false}
          ]
        })

      assert [
               %IntakeProfile{display_name: "one", bio_text_1: "a", is_public?: true},
               %IntakeProfile{display_name: "two", bio_text_1: nil, is_public?: false}
             ] = intake.history
    end

    test "an embedded resource nested in an embedded resource maps both levels" do
      intake =
        create_intake!(%{
          "section" => %{
            "sectionName" => "Main",
            "level1" => 3,
            "profile" => %{"displayName" => "Inner", "bioText1" => "deep", "isPublic" => true}
          }
        })

      assert %IntakeSection{
               section_name: "Main",
               level_1: 3,
               profile: %IntakeProfile{
                 display_name: "Inner",
                 bio_text_1: "deep",
                 is_public?: true
               }
             } = intake.section
    end
  end

  describe "strict nested input keys" do
    defp unknown_nested(input, action \\ "create_intake") do
      assert %{"success" => false, "errors" => errors} =
               run(%{
                 "action" => action,
                 "input" =>
                   if(action == "create_intake",
                     do: Map.put_new(input, "userName", "ada"),
                     else: input
                   ),
                 "fields" => ["id"]
               })

      Enum.map(errors, fn error ->
        assert %{"type" => "unknown_input", "details" => %{"hint" => _}} = error
        assert error["vars"] == %{"field" => hd(error["fields"])}
        {error["path"], hd(error["fields"])}
      end)
    end

    test "a typed-map key in a non-client casing is unknown_input at its path" do
      assert unknown_nested(%{"settings" => %{"notification_enabled" => true}}) ==
               [{["settings"], "notification_enabled"}]
    end

    test "a NewType map key under its internal name is unknown_input" do
      assert unknown_nested(%{"stats" => %{"total_count_1" => 1}}) ==
               [{["stats"], "total_count_1"}]
    end

    test "a NewType map nested in a NewType map reports the full path" do
      assert unknown_nested(%{"deep" => %{"inner" => %{"max_retries_1" => 5}}}) ==
               [{["deep", "inner"], "max_retries_1"}]
    end

    test "keyword and tuple keys are checked" do
      assert unknown_nested(%{"preferences" => %{"font_size" => 14}}) ==
               [{["preferences"], "font_size"}]

      assert unknown_nested(%{"location" => %{"lat1" => 1.0, "lng_1" => 2.0}}) ==
               [{["location"], "lng_1"}]
    end

    test "an embedded resource key is checked, with array indexes in the path" do
      assert unknown_nested(%{"profile" => %{"bio_text_1" => "x"}}) ==
               [{["profile"], "bio_text_1"}]

      assert unknown_nested(%{
               "history" => [%{"displayName" => "one"}, %{"is_public" => true}]
             }) == [{["history", 1], "is_public"}]

      assert unknown_nested(%{"section" => %{"profile" => %{"bioText" => "x"}}}) ==
               [{["section", "profile"], "bioText"}]
    end

    test "keys inside a union member are checked under the member's key" do
      assert unknown_nested(%{"content" => %{"data" => %{"item_count" => 1}}}) ==
               [{["content", "data"], "item_count"}]

      assert unknown_nested(%{
               "status" => %{"active" => %{"statusKind" => "active", "is_final" => true}}
             }) == [{["status", "active"], "is_final"}]

      assert unknown_nested(
               %{"attachments" => [%{"file" => %{"filename" => "a", "mime_type" => "x"}}]},
               "create_widget"
             ) == [{["attachments", 0, "file"], "mime_type"}]
    end

    test "every miss in the input is reported, top-level and nested" do
      assert unknown_nested(%{
               "bogus" => 1,
               "settings" => %{"theme_name" => "dark"},
               "profile" => %{"display_name" => "Ada", "bio_text_1" => "x"}
             })
             |> Enum.sort() ==
               [
                 {[], "bogus"},
                 {["profile"], "bio_text_1"},
                 {["profile"], "display_name"},
                 {["settings"], "theme_name"}
               ]
    end

    test "validate_action reports nested misses the same way" do
      assert %{"success" => false, "errors" => [error]} =
               validate(%{
                 "action" => "create_intake",
                 "input" => %{"userName" => "ada", "settings" => %{"theme_name" => "dark"}}
               })

      assert %{"type" => "unknown_input", "fields" => ["theme_name"], "path" => ["settings"]} =
               error
    end

    test "nothing is written when a nested key misses" do
      before = Ash.read!(Intake) |> length()
      unknown_nested(%{"settings" => %{"theme_name" => "dark"}})
      assert Ash.read!(Intake) |> length() == before
    end

    test "a declared custom type's input keys are client names" do
      assert %{"success" => true, "data" => %{"palette" => %{"accentColor" => "b"}}} =
               run(%{
                 "action" => "create_project",
                 "input" => %{
                   "palette" => %{"primary" => "red", "secondary" => "x", "accentColor" => "b"}
                 },
                 "fields" => [%{"palette" => ["accentColor"]}]
               })
    end

    test "an undeclared key of a declared custom type is unknown_input with its path" do
      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "create_project",
                 "input" => %{
                   "palette" => %{"primary" => "red", "secondary" => "x", "accent_color" => "b"}
                 },
                 "fields" => ["id"]
               })

      assert %{"type" => "unknown_input", "fields" => ["accent_color"], "path" => ["palette"]} =
               error
    end

    test "internal names are client names under snake_case" do
      manifest = AshRpc.Test.ManifestBuilder.build(output_formatter: :snake_case)

      assert %{"success" => true} =
               AshRpc.run_action(
                 @profile,
                 ctx(),
                 %{
                   "action" => "create_intake",
                   "input" => %{
                     "user_name" => "ada",
                     "settings" => %{"notification_enabled" => true},
                     "profile" => %{"display_name" => "Ada"}
                   },
                   "fields" => ["id"]
                 },
                 manifest: manifest
               )
    end
  end

  describe "union input" do
    test "a :type_and_value union maps overrides inside a NewType member" do
      intake =
        create_intake!(%{"content" => %{"data" => %{"itemCount" => 1, "isCached" => true}}})

      assert %Ash.Union{type: :data, value: value} = intake.content
      # The member's tag field is filled in from its tag_value.
      assert value == %{content_type: "data", item_count: 1, is_cached?: true}
    end

    test "a :type_and_value union accepts a simple member" do
      intake = create_intake!(%{"content" => %{"simpleValue" => "plain"}})

      assert %Ash.Union{type: :simple_value, value: "plain"} = intake.content
    end

    test "a :map_with_tag union maps overrides inside an embedded member" do
      intake =
        create_intake!(%{
          "status" => %{
            "active" => %{"statusKind" => "active", "message" => "on", "isFinal" => true}
          }
        })

      assert %Ash.Union{
               type: :active,
               value: %IntakeStatus{status_type: "active", message: "on", is_final?: true}
             } = intake.status
    end

    test "a :map_with_tag tag key is output under the member's client name" do
      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "create_intake",
                 "input" => %{
                   "userName" => "ada",
                   "status" => %{"active" => %{"statusKind" => "active", "message" => "on"}}
                 },
                 "fields" => ["id", %{"status" => [%{"active" => ["statusKind", "message"]}]}]
               })

      assert %{"active" => %{"statusKind" => "active", "message" => "on"}} = data["status"]
      refute Map.has_key?(data["status"]["active"], "statusType")
    end

    test "an array of unions maps each item to its member" do
      assert %{"success" => true, "data" => %{"id" => id}} =
               run(%{
                 "action" => "create_widget",
                 "input" => %{
                   "attachments" => [
                     %{
                       "file" => %{
                         "filename" => "a.pdf",
                         "size" => 10,
                         "mimeType" => "application/pdf"
                       }
                     },
                     %{"image" => %{"filename" => "b.png", "width" => 2, "altText" => "b"}},
                     %{"url" => "https://example.com"}
                   ]
                 },
                 "fields" => ["id"]
               })

      assert [
               %Ash.Union{type: :file, value: file},
               %Ash.Union{type: :image, value: image},
               %Ash.Union{type: :url, value: "https://example.com"}
             ] = Ash.get!(Widget, id).attachments

      assert file == %{filename: "a.pdf", size: 10, mime_type: "application/pdf"}
      assert image == %{filename: "b.png", width: 2, alt_text: "b"}
    end
  end

  describe "action arguments" do
    test "read arguments with overrides map to internal names, including false" do
      ada = Ash.create!(Intake, %{user_name: "ada"})
      Ash.create!(Intake, %{user_name: "bob"})

      params = %{
        "action" => "search_intakes",
        "input" => %{"query" => "ad", "includeDeleted" => false, "filterBy1" => true},
        "fields" => ["id"]
      }

      assert {:ok, %AshRpc.Request{input: input}} =
               AshRpc.Pipeline.parse_request(AshRpc.Runtime.new(@profile), ctx(), params)

      assert input == %{query: "ad", include_deleted?: false, filter_by_1?: true}

      assert %{"success" => true, "data" => [%{"id" => id}]} = run(params)
      assert id == ada.id
    end

    test "a generic action maps overrides inside a NewType argument" do
      assert %{"success" => true, "data" => %{"processed" => true, "resultCount" => 1}} =
               run(%{
                 "action" => "process_intake_data",
                 "input" => %{"inputData" => %{"itemName" => "x", "isValid" => true}},
                 "fields" => ["processed", "resultCount"]
               })
    end

    test "validate_action maps argument and field overrides" do
      search = %{
        "action" => "search_intakes",
        "input" => %{"query" => "x", "includeDeleted" => true, "filterBy1" => false}
      }

      create = %{
        "action" => "create_intake",
        "input" => %{
          "userName" => "ada",
          "isActive" => true,
          "version1" => 1,
          "stats" => %{"totalCount1" => 1, "isComplete" => true}
        }
      }

      assert %{"success" => true} = validate(search)
      assert %{"success" => true} = validate(create)

      # parse_request requires `fields`, which validate_action does not.
      assert {:ok, %AshRpc.Request{input: search_input}} =
               AshRpc.Pipeline.parse_request(
                 AshRpc.Runtime.new(@profile),
                 ctx(),
                 Map.put(search, "fields", ["id"])
               )

      assert search_input == %{query: "x", include_deleted?: true, filter_by_1?: false}

      assert {:ok, %AshRpc.Request{input: create_input}} =
               AshRpc.Pipeline.parse_request(
                 AshRpc.Runtime.new(@profile),
                 ctx(),
                 Map.put(create, "fields", ["id"])
               )

      assert create_input == %{
               user_name: "ada",
               is_active?: true,
               version_1: 1,
               stats: %{total_count_1: 1, is_complete?: true}
             }
    end
  end

  describe "struct arguments" do
    setup do
      %{author: Ash.create!(Author, %{name: "Ada"})}
    end

    defp assign(input) do
      run(%{
        "action" => "catalog_assign",
        "input" => input,
        "fields" => ["assigneeId", "assigneeName", "reason"]
      })
    end

    test "a map of resource fields is cast to the struct", %{author: author} do
      assert %{"success" => true, "data" => data} =
               assign(%{
                 "assignee" => %{"id" => author.id, "name" => "Ada", "isActive" => true},
                 "reason" => "review"
               })

      assert data == %{"assigneeId" => author.id, "assigneeName" => "Ada", "reason" => "review"}
    end

    test "an optional sibling argument can be omitted", %{author: author} do
      assert %{"success" => true, "data" => data} =
               assign(%{"assignee" => %{"id" => author.id, "name" => "Ada"}})

      assert data == %{"assigneeId" => author.id, "assigneeName" => "Ada", "reason" => nil}
    end

    test "an empty map fails the struct cast with an invalid_argument per missing field" do
      assert %{"success" => false, "errors" => errors} = assign(%{"assignee" => %{}})

      assert Enum.sort_by(errors, & &1["fields"]) ==
               for(
                 field <- ["id", "name"],
                 do: %{
                   "type" => "invalid_argument",
                   "message" => "field must be present",
                   "shortMessage" => "Invalid argument",
                   "fields" => [field],
                   "path" => ["assignee"],
                   "vars" => %{"field" => field}
                 }
               )
    end

    test "an array of maps is cast to an array of structs", %{author: author} do
      other = Ash.create!(Author, %{name: "Bob"})

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "catalog_assign_many",
                 "input" => %{
                   "assignees" => [
                     %{"id" => author.id, "name" => "Ada"},
                     %{"id" => other.id, "name" => "Bob"}
                   ]
                 },
                 "fields" => ["assigneeId", "assigneeName"]
               })

      assert data == [
               %{"assigneeId" => author.id, "assigneeName" => "Ada"},
               %{"assigneeId" => other.id, "assigneeName" => "Bob"}
             ]
    end

    test "a struct input on an unexposed domain resource takes formatter names" do
      post_id = Ash.UUID.generate()
      voucher = %{"id" => Ash.UUID.generate(), "voucherCode" => "V1", "postId" => post_id}

      assert %{"success" => true, "data" => data} =
               run(%{
                 "action" => "catalog_redeem_voucher",
                 "input" => %{"voucher" => voucher},
                 "fields" => ["voucherCode", "postId"]
               })

      assert data == %{"voucherCode" => "V1", "postId" => post_id}
    end

    test "a struct input on an unexposed domain resource has strict keys" do
      voucher = %{"id" => Ash.UUID.generate(), "voucher_code" => "V1"}

      assert %{"success" => false, "errors" => [error]} =
               run(%{
                 "action" => "catalog_redeem_voucher",
                 "input" => %{"voucher" => voucher},
                 "fields" => ["voucherCode"]
               })

      assert error["type"] == "unknown_input"
      assert error["fields"] == ["voucher_code"]
      assert error["path"] == ["voucher"]
    end

    test "an empty array returns an empty list" do
      assert %{"success" => true, "data" => []} =
               run(%{
                 "action" => "catalog_assign_many",
                 "input" => %{"assignees" => []},
                 "fields" => ["assigneeId", "assigneeName"]
               })
    end
  end

  describe "custom type input" do
    defp create_project(input, fields) do
      run(%{"action" => "create_project", "input" => input, "fields" => fields})
    end

    test "a string is cast by the type and returned as a list" do
      assert %{"success" => true, "data" => data} =
               create_project(%{"trail" => "projects.web.frontend"}, ["trail"])

      assert data == %{"trail" => ["projects", "web", "frontend"]}
    end

    test "a list is accepted as is, alongside a strict attribute" do
      assert %{"success" => true, "data" => data} =
               create_project(
                 %{"trail" => ["projects", "web", "api"], "strictTrail" => ["a", "b"]},
                 ["trail", "strictTrail"]
               )

      assert data == %{"trail" => ["projects", "web", "api"], "strictTrail" => ["a", "b"]}
    end

    test "an omitted value is nil, and an update replaces or clears it" do
      assert %{"success" => true, "data" => %{"id" => id, "trail" => nil}} =
               create_project(%{}, ["id", "trail"])

      update = fn input ->
        run(%{
          "action" => "update_project",
          "identity" => id,
          "input" => input,
          "fields" => ["trail", "strictTrail"]
        })
      end

      assert %{"success" => true, "data" => data} =
               update.(%{"trail" => "updated.path.to.item", "strictTrail" => ["x", "y"]})

      assert data == %{"trail" => ["updated", "path", "to", "item"], "strictTrail" => ["x", "y"]}

      assert %{"success" => true, "data" => data} =
               update.(%{"trail" => nil, "strictTrail" => nil})

      assert data == %{"trail" => nil, "strictTrail" => nil}
      assert %{trail: nil, strict_trail: nil} = Ash.get!(AshRpc.Test.Project, id)
    end

    test "a strict attribute rejects a string with the type's message" do
      assert %{"success" => false, "errors" => errors} =
               create_project(%{"strictTrail" => "projects.mobile"}, ["id"])

      assert errors == [
               %{
                 "type" => "invalid_attribute",
                 "message" => "must be a list of labels, got a string",
                 "shortMessage" => "Invalid attribute",
                 "fields" => ["strictTrail"],
                 "path" => [],
                 "vars" => %{"field" => "strictTrail"}
               }
             ]

      assert Ash.read!(AshRpc.Test.Project) == []
    end
  end
end
