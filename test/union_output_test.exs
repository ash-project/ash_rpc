# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.UnionOutputTest do
  use ExUnit.Case, async: true

  alias AshRpc.Test.{ChecklistBlock, TextBlock, Widget}

  # Widget unions:
  # - content (:type_and_value): text/checklist embedded members tagged by
  #   content_type, note (string), priority_value (integer 1..10)
  # - status (:map_with_tag): simple/detailed maps tagged by status_type
  # - attachments (array): file/image typed maps tagged by attachment_type, url (string)
  @profile AshRpc.Test.Profile

  defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

  defp create!(input, fields \\ ["id"]) do
    assert %{"success" => true, "data" => data} =
             run(%{"action" => "create_widget", "input" => input, "fields" => fields})

    data
  end

  defp list!(fields) do
    assert %{"success" => true, "data" => data} =
             run(%{"action" => "list_widgets", "fields" => fields})

    Enum.sort_by(data, & &1["id"])
  end

  defp list_error(fields) do
    assert %{"success" => false, "errors" => [error]} =
             run(%{"action" => "list_widgets", "fields" => fields})

    error
  end

  defp sort_by_id(records), do: Enum.sort_by(records, & &1["id"])

  describe "tagged member input" do
    test "a wrapped embedded member picks that member and injects its tag" do
      %{"id" => id, "content" => content} =
        create!(
          %{"content" => %{"text" => %{"text" => "Hello", "wordCount" => 2}}},
          ["id", %{"content" => [%{"text" => ["text", "wordCount", "contentType"]}]}]
        )

      assert content == %{
               "text" => %{"text" => "Hello", "wordCount" => 2, "contentType" => "text"}
             }

      assert %Ash.Union{type: :text, value: %TextBlock{} = block} =
               Ash.get!(Widget, id).content

      assert %{text: "Hello", word_count: 2, content_type: "text"} = block
    end

    test "a tag key in the input map picks the member even when another member key is present" do
      %{"id" => id} =
        create!(%{
          "content" => %{
            "contentType" => "checklist",
            "checklist" => %{"title" => "Groceries"},
            "note" => "ignored"
          }
        })

      assert [%Widget{id: ^id, content: %Ash.Union{type: :checklist, value: block}}] =
               Ash.read!(Widget)

      assert %ChecklistBlock{title: "Groceries", content_type: "checklist"} = block
    end
  end

  describe "embedded member output" do
    test "a text member returns its attributes and calculations" do
      %{"id" => id} = create!(%{"content" => %{"text" => %{"text" => "Hello", "wordCount" => 2}}})

      assert list!(["id", %{"content" => [%{"text" => ["text", "wordCount", "displayText"]}]}]) ==
               [
                 %{
                   "id" => id,
                   "content" => %{
                     "text" => %{
                       "text" => "Hello",
                       "wordCount" => 2,
                       "displayText" => "text:Hello"
                     }
                   }
                 }
               ]
    end

    test "a checklist member returns nested items, a mapped field name and a calculation" do
      %{"id" => id} =
        create!(%{
          "content" => %{
            "checklist" => %{
              "title" => "Groceries",
              "items" => [
                %{"text" => "Milk", "completed" => false},
                %{"text" => "Bread", "completed" => true}
              ],
              "isActive" => true
            }
          }
        })

      assert list!([
               "id",
               %{
                 "content" => [
                   %{
                     "checklist" => [
                       "title",
                       %{"items" => ["text", "completed"]},
                       "isActive",
                       "totalItems"
                     ]
                   }
                 ]
               }
             ]) == [
               %{
                 "id" => id,
                 "content" => %{
                   "checklist" => %{
                     "title" => "Groceries",
                     "items" => [
                       %{"text" => "Milk", "completed" => false},
                       %{"text" => "Bread", "completed" => true}
                     ],
                     "isActive" => true,
                     "totalItems" => 2
                   }
                 }
               }
             ]
    end

    test "only the selected member fields are returned" do
      %{"id" => id} = create!(%{"content" => %{"text" => %{"text" => "Hello", "wordCount" => 2}}})

      assert list!(["id", %{"content" => [%{"text" => ["wordCount"]}]}]) == [
               %{"id" => id, "content" => %{"text" => %{"wordCount" => 2}}}
             ]
    end
  end

  describe "scalar members" do
    test "note and priorityValue round-trip through input and output" do
      assert %{"content" => %{"note" => "Remember"}} =
               create!(%{"content" => %{"note" => "Remember"}}, ["id", %{"content" => ["note"]}])

      assert %{"content" => %{"priorityValue" => 8}} =
               create!(%{"content" => %{"priorityValue" => 8}}, [
                 "id",
                 %{"content" => ["priorityValue"]}
               ])
    end

    test "records with different active members come back in one list" do
      %{"id" => note_id} = create!(%{"content" => %{"note" => "Remember"}})
      %{"id" => priority_id} = create!(%{"content" => %{"priorityValue" => 3}})
      %{"id" => text_id} = create!(%{"content" => %{"text" => %{"text" => "Hello"}}})

      fields = ["id", %{"content" => ["note", "priorityValue", %{"text" => ["text"]}]}]

      assert list!(fields) ==
               sort_by_id([
                 %{"id" => note_id, "content" => %{"note" => "Remember"}},
                 %{"id" => priority_id, "content" => %{"priorityValue" => 3}},
                 %{"id" => text_id, "content" => %{"text" => %{"text" => "Hello"}}}
               ])
    end
  end

  describe "only the requested member is emitted" do
    test "a record whose active member is not requested emits nil for the union" do
      %{"id" => note_id} = create!(%{"content" => %{"note" => "Remember"}})
      %{"id" => text_id} = create!(%{"content" => %{"text" => %{"text" => "Hello"}}})

      assert list!(["id", %{"content" => ["note"]}]) ==
               sort_by_id([
                 %{"id" => note_id, "content" => %{"note" => "Remember"}},
                 %{"id" => text_id, "content" => nil}
               ])
    end

    test "members listed in one map or in separate maps select the same output" do
      %{"id" => text_id} = create!(%{"content" => %{"text" => %{"text" => "Hello"}}})

      %{"id" => checklist_id} =
        create!(%{"content" => %{"checklist" => %{"title" => "Groceries"}}})

      expected =
        sort_by_id([
          %{"id" => text_id, "content" => %{"text" => %{"text" => "Hello"}}},
          %{"id" => checklist_id, "content" => %{"checklist" => %{"title" => "Groceries"}}}
        ])

      assert list!(["id", %{"content" => [%{"text" => ["text"], "checklist" => ["title"]}]}]) ==
               expected

      assert list!(["id", %{"content" => [%{"text" => ["text"]}, %{"checklist" => ["title"]}]}]) ==
               expected
    end
  end

  describe "map_with_tag storage" do
    test "members are selected by name and come back with camelCased keys and the tag" do
      %{"id" => simple_id} =
        create!(%{"status" => %{"simple" => %{"message" => "Started"}}})

      %{"id" => detailed_id} =
        create!(%{
          "status" => %{
            "detailed" => %{"message" => "Halfway", "progressPercentage" => 45}
          }
        })

      assert list!(["id", %{"status" => ["simple", "detailed"]}]) ==
               sort_by_id([
                 %{
                   "id" => simple_id,
                   "status" => %{"simple" => %{"message" => "Started", "statusType" => "simple"}}
                 },
                 %{
                   "id" => detailed_id,
                   "status" => %{
                     "detailed" => %{
                       "message" => "Halfway",
                       "progressPercentage" => 45,
                       "statusType" => "detailed"
                     }
                   }
                 }
               ])

      assert list!(["id", %{"status" => ["simple"]}]) ==
               sort_by_id([
                 %{
                   "id" => simple_id,
                   "status" => %{"simple" => %{"message" => "Started", "statusType" => "simple"}}
                 },
                 %{"id" => detailed_id, "status" => nil}
               ])
    end
  end

  describe "array union of tagged typed-map members" do
    @attachments [
      %{"file" => %{"filename" => "doc.pdf", "size" => 1024, "mimeType" => "application/pdf"}},
      %{
        "image" => %{"filename" => "shot.png", "width" => 800, "height" => 600, "altText" => "A"}
      },
      %{"url" => "https://example.com"}
    ]

    test "one member per selection map" do
      fields = [
        "id",
        %{
          "attachments" => [
            %{"file" => ["filename", "size", "mimeType"]},
            %{"image" => ["filename", "width", "height", "altText"]},
            "url"
          ]
        }
      ]

      assert %{"attachments" => @attachments} =
               create!(%{"attachments" => @attachments}, fields)
    end

    test "several members in one selection map" do
      %{"id" => id} = create!(%{"attachments" => @attachments})

      fields = [
        "id",
        %{
          "attachments" => [
            "url",
            %{
              "file" => ["filename", "size", "mimeType"],
              "image" => ["filename", "width", "height", "altText"]
            }
          ]
        }
      ]

      assert list!(fields) == [%{"id" => id, "attachments" => @attachments}]
    end

    # Unlike a scalar union, which emits nil, an array drops the items whose
    # active member wasn't requested.
    test "field selection inside a member keeps only the selected keys and drops unrequested items" do
      %{"id" => id} = create!(%{"attachments" => @attachments})

      assert list!([
               "id",
               %{"attachments" => [%{"file" => ["filename"]}, %{"image" => ["width"]}]}
             ]) ==
               [
                 %{
                   "id" => id,
                   "attachments" => [
                     %{"file" => %{"filename" => "doc.pdf"}},
                     %{"image" => %{"width" => 800}}
                   ]
                 }
               ]
    end
  end

  test "unions are returned next to plain attributes and a relationship" do
    post = Ash.create!(AshRpc.Test.Post, %{title: "Hello"})

    %{"id" => id} =
      create!(%{
        "postId" => post.id,
        "content" => %{"text" => %{"text" => "Body"}},
        "attachments" => [%{"url" => "https://example.com"}]
      })

    assert list!([
             "id",
             "postId",
             %{"post" => ["id", "title"]},
             %{"content" => ["note", %{"text" => ["text"]}]},
             %{"attachments" => ["url"]}
           ]) == [
             %{
               "id" => id,
               "postId" => post.id,
               "post" => %{"id" => post.id, "title" => "Hello"},
               "content" => %{"text" => %{"text" => "Body"}},
               "attachments" => [%{"url" => "https://example.com"}]
             }
           ]
  end

  describe "selection errors" do
    test "an unknown member is unknown_union_field" do
      for {fields, field, path} <- [
            {[%{"content" => ["invalidMember"]}], "content.invalidMember", ["content"]},
            {[%{"attachments" => ["invalidKind"]}], "attachments.invalidKind", ["attachments"]},
            {[%{"status" => ["invalidStatus"]}], "status.invalidStatus", ["status"]}
          ] do
        assert %{
                 "type" => "unknown_union_field",
                 "fields" => [^field],
                 "path" => ^path,
                 "vars" => %{"field" => ^field}
               } = list_error(fields)
      end
    end

    test "an unknown field in an embedded member is unknown_field" do
      assert %{
               "type" => "unknown_field",
               "fields" => ["content.text.invalidField"],
               "path" => ["content", "text"],
               "vars" => %{
                 "field" => "content.text.invalidField"
               }
             } = list_error([%{"content" => [%{"text" => ["text", "invalidField"]}]}])
    end

    test "an unknown field in a typed-map member is unknown_map_field" do
      assert %{
               "type" => "unknown_map_field",
               "fields" => ["attachments.file.invalidField"],
               "path" => ["attachments", "file"],
               "vars" => %{"field" => "attachments.file.invalidField"}
             } = list_error([%{"attachments" => [%{"file" => ["filename", "invalidField"]}]}])
    end

    test "a bare union attribute requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["content"],
               "path" => [],
               "vars" => %{"field" => "content", "fieldType" => "Union"}
             } = list_error(["content"])
    end

    test "a bare complex member requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["content.text"],
               "path" => ["content"],
               "vars" => %{"field" => "content.text", "fieldType" => "Union member"}
             } = list_error([%{"content" => ["text"]}])

      assert %{
               "type" => "requires_field_selection",
               "fields" => ["attachments.file"],
               "path" => ["attachments"],
               "vars" => %{"field" => "attachments.file", "fieldType" => "Union member"}
             } = list_error([%{"attachments" => ["file"]}])
    end

    test "an empty selection requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["content"],
               "path" => [],
               "vars" => %{"field" => "content", "fieldType" => "Union"}
             } = list_error([%{"content" => []}])
    end

    test "an empty selection on an embedded member requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["content.text"],
               "path" => ["content"],
               "vars" => %{"field" => "content.text", "fieldType" => "Union member"}
             } = list_error([%{"content" => [%{"text" => []}]}])
    end

    test "an empty selection on a typed-map member requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["attachments.file"],
               "path" => ["attachments"],
               "vars" => %{"field" => "attachments.file", "fieldType" => "Union member"}
             } = list_error([%{"attachments" => [%{"file" => []}]}])
    end

    test "a member selection that is not a list is unsupported_field_combination" do
      for {selection, spec} <- [
            {%{"text" => "x"}, ~s("x")},
            {%{"text" => 5}, "5"},
            {[%{"text" => "x"}], ~s("x")},
            {[%{"text" => %{"text" => 1}}], ~s(%{"text" => 1})}
          ] do
        assert %{
                 "type" => "unsupported_field_combination",
                 "message" =>
                   "Unsupported combination of field type and specification for %{field}",
                 "fields" => ["content.text"],
                 "path" => ["content"],
                 "vars" => %{"field" => "content.text", "fieldType" => "union member"},
                 "details" => %{"fieldSpec" => ^spec}
               } = list_error([%{"content" => selection}])
      end
    end

    test "a member listed twice is duplicate_field without a hint" do
      for {selection, field} <- [
            {["note", "note"], "content.note"},
            {[%{"text" => ["text"]}, %{"text" => ["text", "wordCount"]}], "content.text"},
            {["note", %{"note" => ["invalid"]}], "content.note"}
          ] do
        assert %{
                 "type" => "duplicate_field",
                 "fields" => [^field],
                 "path" => ["content"],
                 "vars" => %{"field" => ^field},
                 "details" => details
               } = list_error([%{"content" => selection}])

        refute Map.has_key?(details, "hint")
      end
    end
  end

  test "an invalid member key in array union input is invalid_union_input" do
    assert %{"success" => false, "errors" => [error]} =
             run(%{
               "action" => "create_widget",
               "input" => %{"attachments" => [%{"invalidKind" => "value"}]},
               "fields" => ["id"]
             })

    assert %{
             "type" => "invalid_union_input",
             "message" => "Union input map does not contain any valid member key",
             "vars" => %{"expectedMembers" => "file, image, url"},
             "details" => %{"expectedMembers" => ["file", "image", "url"]}
           } = error
  end

  describe "extraction templates" do
    setup do
      %{rt: AshRpc.Runtime.new(@profile)}
    end

    test "a tagged union nests member selections under the attribute", %{rt: rt} do
      assert {:ok, {select, load, template}} =
               AshRpc.RequestedFieldsProcessor.process(rt, Widget, :read, [
                 "id",
                 %{
                   "content" => [
                     "note",
                     %{"text" => ["text", "wordCount"], "checklist" => ["title", "isActive"]}
                   ]
                 }
               ])

      assert select == [:id, :content]
      assert load == []
      # Members from one selection map come out in map key order.
      assert template == [
               :id,
               content: [:note, checklist: [:title, :is_active?], text: [:text, :word_count]]
             ]
    end

    test "an array union nests member selections under the attribute", %{rt: rt} do
      assert {:ok, {select, load, template}} =
               AshRpc.RequestedFieldsProcessor.process(rt, Widget, :read, [
                 "id",
                 %{"attachments" => [%{"file" => ["filename", "size"]}, "url"]}
               ])

      assert select == [:id, :attachments]
      assert load == []
      assert template == [:id, attachments: [:url, file: [:filename, :size]]]
    end
  end

  describe "generic action returning a union" do
    @invalid_union_return %{
      "type" => "invalid_union_return",
      "message" => "Action %{action} must return an Ash.Union value, not a bare member value",
      "shortMessage" => "Invalid union return",
      "vars" => %{"action" => "payload"},
      "path" => [],
      "fields" => [],
      "details" => %{}
    }

    test "an Ash.Union value comes back under its member name" do
      assert %{"success" => true, "data" => %{"stats" => %{"wordCount1" => 3}}} ==
               run(%{
                 "action" => "payload",
                 "input" => %{"shape" => "union"},
                 "fields" => [%{"stats" => ["wordCount1"]}]
               })
    end

    test "a bare member value is invalid_union_return" do
      assert %{"success" => false, "errors" => [@invalid_union_return]} ==
               run(%{"action" => "payload", "fields" => ["text"]})
    end

    test "a member selection that is not a list is unsupported_field_combination" do
      assert %{
               "success" => false,
               "errors" => [
                 %{
                   "type" => "unsupported_field_combination",
                   "fields" => ["stats"],
                   "path" => [],
                   "vars" => %{"field" => "stats", "fieldType" => "union member"},
                   "details" => %{"fieldSpec" => ~s("x")}
                 }
               ]
             } =
               run(%{
                 "action" => "payload",
                 "input" => %{"shape" => "union"},
                 "fields" => [%{"stats" => "x"}]
               })
    end

    test "an empty or missing selection is requires_field_selection" do
      expected = %{
        "type" => "requires_field_selection",
        "message" => "%{fieldType} requires field selection",
        "shortMessage" => "Field selection required",
        "vars" => %{"fieldType" => "Union"},
        "path" => [],
        "fields" => [],
        "details" => %{
          "suggestion" => "Specify which fields to select from this union",
          "hint" => AshRpc.Profile.default_stale_client_hint()
        }
      }

      assert %{"success" => false, "errors" => [^expected]} =
               run(%{"action" => "payload", "fields" => []})

      assert %{"success" => false, "errors" => [^expected]} = run(%{"action" => "payload"})
    end

    test "invalid_union_return is logged with the value's type, not the value" do
      for {params, kind} <- [
            {%{"action" => "payload", "fields" => ["text"]}, "a string"},
            {%{"action" => "payload", "input" => %{"shape" => "map"}, "fields" => ["text"]},
             "a map"},
            {%{"action" => "payloads", "input" => %{"bare" => true}, "fields" => ["text"]},
             "a string"}
          ] do
        log = ExUnit.CaptureLog.capture_log(fn -> run(params) end)

        assert log =~
                 "Generic action #{inspect(AshRpc.Test.Post)}.#{params["action"]} " <>
                   "(entrypoint #{params["action"]}) returned #{kind} where its union return " <>
                   "type needs an %Ash.Union{}"

        refute log =~ "hello"
        refute log =~ "word_count_1"
      end
    end

    test "a bare map is invalid_union_return" do
      assert %{"success" => false, "errors" => [@invalid_union_return]} ==
               run(%{
                 "action" => "payload",
                 "input" => %{"shape" => "map"},
                 "fields" => [%{"stats" => ["wordCount1"]}]
               })
    end

    test "the value formatter gives a bare member value no member" do
      rt = AshRpc.Runtime.new(@profile)
      returns = Map.fetch!(rt.action_lookup, {AshRpc.Test.Post, :payload}).returns

      assert AshRpc.ValueFormatter.format("hello", returns, [], :output, rt) == %{}
    end

    test "an array of Ash.Union values comes back per item" do
      assert %{"success" => true, "data" => [%{"text" => "hi"}, %{"text" => "yo"}]} ==
               run(%{"action" => "payloads", "fields" => ["text"]})
    end

    test "a bare item in an array is invalid_union_return" do
      assert %{
               "success" => false,
               "errors" => [%{@invalid_union_return | "vars" => %{"action" => "payloads"}}]
             } ==
               run(%{"action" => "payloads", "input" => %{"bare" => true}, "fields" => ["text"]})
    end
  end
end
