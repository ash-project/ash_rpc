# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.KeywordTupleTest do
  use ExUnit.Case, async: true

  alias AshRpc.{InputFormatter, RequestedFieldsProcessor, Runtime, ValueFormatter}
  alias AshRpc.Test.{GeoPoint, Place}

  @profile AshRpc.Test.Profile

  defp run(params), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params)

  defp create_place!(input) do
    assert %{"success" => true, "data" => %{"id" => id}} =
             run(%{"action" => "create_place", "input" => input, "fields" => ["id"]})

    id
  end

  defp get_place(fields), do: run(%{"action" => "get_place", "fields" => fields})

  defp error!(params) do
    assert %{"success" => false, "errors" => [error]} = run(params)
    error
  end

  describe "keyword attribute input" do
    test "a JSON map is converted to a keyword list" do
      id =
        create_place!(%{
          "options" => %{"priority" => 8, "category" => "work", "notify" => true}
        })

      assert Ash.get!(Place, id).options == [priority: 8, category: "work", notify: true]
    end
  end

  describe "keyword attribute output" do
    setup do
      create_place!(%{"options" => %{"priority" => 8, "category" => "work", "notify" => true}})
      :ok
    end

    test "full selection comes back as a map with client keys" do
      assert %{
               "success" => true,
               "data" => %{
                 "options" => %{"priority" => 8, "category" => "work", "notify" => true}
               }
             } == get_place([%{"options" => ["priority", "category", "notify"]}])
    end

    test "partial selection returns only the requested keys" do
      assert %{"success" => true, "data" => %{"options" => %{"priority" => 8, "notify" => true}}} ==
               get_place([%{"options" => ["priority", "notify"]}])
    end

    test "single selection returns only that key" do
      assert %{"success" => true, "data" => %{"options" => %{"category" => "work"}}} ==
               get_place([%{"options" => ["category"]}])
    end

    test "the create response formats the keyword value the same way" do
      assert %{
               "success" => true,
               "data" => %{
                 "options" => %{"priority" => 3, "category" => "home", "notify" => false}
               }
             } ==
               run(%{
                 "action" => "create_place",
                 "input" => %{
                   "options" => %{"priority" => 3, "category" => "home", "notify" => false}
                 },
                 "fields" => [%{"options" => ["priority", "category", "notify"]}]
               })
    end
  end

  test "an unset keyword attribute comes back as nil" do
    create_place!(%{})

    assert %{"success" => true, "data" => [%{"options" => nil}]} ==
             run(%{
               "action" => "list_places",
               "fields" => [%{"options" => ["priority", "category", "notify"]}]
             })
  end

  describe "keyword attribute field selection errors" do
    test "a bare keyword attribute requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["options"],
               "path" => [],
               "vars" => %{"field" => "options", "fieldType" => "Field_constrained_type"}
             } = error!(%{"action" => "list_places", "fields" => ["id", "options"]})
    end

    test "an empty keyword selection requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["options"],
               "path" => [],
               "vars" => %{"field" => "options", "fieldType" => "Field_constrained_type"}
             } = error!(%{"action" => "list_places", "fields" => ["id", %{"options" => []}]})
    end

    test "an unknown keyword key is unknown_field of kind field_constrained_type" do
      assert {:error, {:unknown_field, :invalid_field, "field_constrained_type", [:options]}} =
               RequestedFieldsProcessor.process(Runtime.new(@profile), Place, :read, [
                 %{"options" => ["priority", "invalid_field"]}
               ])

      assert %{
               "type" => "unknown_field",
               "fields" => ["options.invalidField"],
               "path" => ["options"],
               "vars" => %{"field" => "options.invalidField", "kind" => "field constrained"}
             } =
               error!(%{
                 "action" => "list_places",
                 "fields" => [%{"options" => ["priority", "invalidField"]}]
               })
    end
  end

  describe "generic action returning a keyword list" do
    test "full selection returns every key, atoms as strings" do
      assert %{
               "success" => true,
               "data" => %{
                 "priority" => 8,
                 "category" => "work",
                 "notify" => true,
                 "theme" => "dark"
               }
             } ==
               run(%{
                 "action" => "place_keyword_options",
                 "fields" => ["priority", "category", "notify", "theme"]
               })
    end

    test "partial selection returns only the requested keys" do
      assert %{"success" => true, "data" => %{"priority" => 8, "notify" => true}} ==
               run(%{"action" => "place_keyword_options", "fields" => ["priority", "notify"]})
    end

    test "single selection returns only that key" do
      assert %{"success" => true, "data" => %{"theme" => "dark"}} ==
               run(%{"action" => "place_keyword_options", "fields" => ["theme"]})
    end
  end

  describe "tuple attribute" do
    test "a JSON map input is converted to a tuple in field order" do
      id = create_place!(%{"coordinates" => %{"longitude" => -122.4194, "latitude" => 37.7749}})

      assert Ash.get!(Place, id).coordinates == {37.7749, -122.4194}
    end

    test "full selection comes back as a map with client keys" do
      create_place!(%{"coordinates" => %{"latitude" => 37.7749, "longitude" => -122.4194}})

      assert %{
               "success" => true,
               "data" => %{"coordinates" => %{"latitude" => 37.7749, "longitude" => -122.4194}}
             } == get_place([%{"coordinates" => ["latitude", "longitude"]}])
    end

    test "partial selection returns only the requested element" do
      create_place!(%{"coordinates" => %{"latitude" => 37.7749, "longitude" => -122.4194}})

      assert %{"success" => true, "data" => %{"coordinates" => %{"latitude" => 37.7749}}} ==
               get_place([%{"coordinates" => ["latitude"]}])
    end

    test "an unset tuple attribute comes back as nil" do
      create_place!(%{})

      assert %{"success" => true, "data" => %{"coordinates" => nil}} ==
               get_place([%{"coordinates" => ["latitude", "longitude"]}])
    end

    test "a bare tuple attribute requires field selection" do
      assert %{
               "type" => "requires_field_selection",
               "fields" => ["coordinates"],
               "path" => [],
               "vars" => %{"field" => "coordinates", "fieldType" => "Tuple"}
             } = error!(%{"action" => "list_places", "fields" => ["id", "coordinates"]})
    end
  end

  describe "generic action returning a tuple" do
    test "full selection returns every element, altitude as an integer" do
      assert %{
               "success" => true,
               "data" => %{"latitude" => 37.7749, "longitude" => -122.4194, "altitude" => 50}
             } ==
               run(%{
                 "action" => "place_coordinates_info",
                 "fields" => ["latitude", "longitude", "altitude"]
               })
    end

    test "partial selection returns only the requested elements" do
      assert %{"success" => true, "data" => %{"latitude" => 37.7749, "longitude" => -122.4194}} ==
               run(%{"action" => "place_coordinates_info", "fields" => ["latitude", "longitude"]})
    end

    test "single selection returns only that element" do
      assert %{"success" => true, "data" => %{"altitude" => 50}} ==
               run(%{"action" => "place_coordinates_info", "fields" => ["altitude"]})
    end
  end

  describe "extraction templates" do
    setup do
      %{runtime: Runtime.new(@profile)}
    end

    test "a tuple attribute template lists each element with its index", %{runtime: rt} do
      assert {:ok,
              {[:coordinates], [],
               [
                 coordinates: [
                   %{index: 0, field_name: :latitude},
                   %{index: 1, field_name: :longitude}
                 ]
               ]}} ==
               RequestedFieldsProcessor.process(rt, Place, :read, [
                 %{"coordinates" => ["latitude", "longitude"]}
               ])
    end

    test "keyword and tuple attributes share one template", %{runtime: rt} do
      assert {:ok,
              {[:id, :options, :coordinates], [],
               [
                 :id,
                 {:options, [:priority, :category]},
                 {:coordinates, [%{index: 1, field_name: :longitude}]}
               ]}} ==
               RequestedFieldsProcessor.process(rt, Place, :read, [
                 "id",
                 %{"options" => ["priority", "category"]},
                 %{"coordinates" => ["longitude"]}
               ])
    end
  end

  describe "tuple NewType with client field-name overrides" do
    setup do
      %{runtime: Runtime.new(@profile)}
    end

    test "input and output use the override names over the wire" do
      assert %{
               "success" => true,
               "data" => %{
                 "id" => id,
                 "location" => %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}
               }
             } =
               run(%{
                 "action" => "create_place",
                 "input" => %{
                   "location" => %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}
                 },
                 "fields" => ["id", %{"location" => ["lat1", "lng1", "isVerified"]}]
               })

      assert Ash.get!(Place, id).location == {37.7749, -122.4194, true}
    end

    test "ValueFormatter maps override names to field names on input", %{runtime: rt} do
      input = %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}

      assert ValueFormatter.format(input, GeoPoint, [], :input, rt) ==
               %{lat_1: 37.7749, lng_1: -122.4194, is_verified?: true}
    end

    test "ValueFormatter maps field names to override names on output", %{runtime: rt} do
      value = %{lat_1: 37.7749, lng_1: -122.4194, is_verified?: true}

      assert ValueFormatter.format(value, GeoPoint, [], :output, rt) ==
               %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}
    end

    test "InputFormatter maps a tuple NewType attribute's override names", %{runtime: rt} do
      raw = %{"location" => %{"lat1" => 37.7749, "lng1" => -122.4194, "isVerified" => true}}

      assert InputFormatter.format(raw, Place, :create, rt) ==
               {:ok, %{location: %{lat_1: 37.7749, lng_1: -122.4194, is_verified?: true}}}
    end
  end
end
