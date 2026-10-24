# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.CustomTypeFieldsTest do
  # Declared custom types (`Palette` with map storage, the composite `Amount`)
  # are typed maps on the wire: selected by sub-field, named by client names,
  # and strict about input keys.
  use ExUnit.Case, async: true

  alias AshRpc.Test.ManifestBuilder

  @profile AshRpc.Test.Profile

  defp run(params, opts \\ []), do: AshRpc.run_action(@profile, %AshRpc.Context{}, params, opts)

  defp ok!(params) do
    assert %{"success" => true, "data" => data} = run(params)
    data
  end

  defp error!(params) do
    assert %{"success" => false, "errors" => [error]} = run(params)
    error
  end

  @palette %{"primary" => "red", "secondary" => "blue", "accentColor" => "teal"}

  describe "a composite type with struct values" do
    test "is extracted to declared fields only" do
      data =
        ok!(%{
          "action" => "catalog_amount_result",
          "fields" => ["currency", "value", %{"breakdown" => ["net", "taxRate"]}]
        })

      assert data == %{
               "currency" => "EUR",
               "value" => "1.50",
               "breakdown" => %{"net" => "1.20", "taxRate" => "0.25"}
             }
    end

    test "a bare typed field inside it comes back whole, as in any typed-map return" do
      assert %{"breakdown" => %{"net" => "1.20", "taxRate" => "0.25"}} =
               ok!(%{"action" => "catalog_amount_result", "fields" => ["currency", "breakdown"]})
    end

    test "a return without fields is missing_required_parameter, as for typed maps" do
      assert %{"type" => "missing_required_parameter", "vars" => %{"parameter" => "fields"}} =
               error!(%{"action" => "catalog_amount_result"})
    end

    test "the TypedStruct inside declared fields has strict input keys" do
      assert %{
               "type" => "unknown_input",
               "fields" => ["tax_rate"],
               "path" => ["amount", "breakdown"]
             } =
               error!(%{
                 "action" => "create_swatch",
                 "input" => %{
                   "amount" => %{
                     "currency" => "EUR",
                     "value" => "2",
                     "breakdown" => %{"tax_rate" => "0.1"}
                   }
                 },
                 "fields" => ["id"]
               })
    end
  end

  test "arrays, union members, calculations and first aggregates of a declared type" do
    %{"id" => box_id} = ok!(%{"action" => "create_swatch_box", "fields" => ["id"]})

    %{"id" => swatch_id} =
      ok!(%{
        "action" => "create_swatch",
        "input" => %{
          "boxId" => box_id,
          "palette" => @palette,
          "palettes" => [@palette, %{"primary" => "black", "secondary" => "white"}],
          "choice" => %{"palette" => @palette}
        },
        "fields" => ["id"]
      })

    swatches =
      ok!(%{
        "action" => "list_swatches",
        "fields" => [
          "id",
          %{"palettes" => ["primary"]},
          %{"choice" => [%{"palette" => ["accentColor"]}, "label"]},
          %{"paletteEcho" => ["secondary"]}
        ]
      })

    assert Enum.find(swatches, &(&1["id"] == swatch_id)) == %{
             "id" => swatch_id,
             "palettes" => [%{"primary" => "red"}, %{"primary" => "black"}],
             "choice" => %{"palette" => %{"accentColor" => "teal"}},
             "paletteEcho" => %{"secondary" => "blue"}
           }

    boxes =
      ok!(%{
        "action" => "list_swatch_boxes",
        "fields" => ["id", %{"firstPalette" => ["primary"]}]
      })

    assert Enum.find(boxes, &(&1["id"] == box_id)) == %{
             "id" => box_id,
             "firstPalette" => %{"primary" => "red"}
           }
  end

  test "snake_case and pascal_case manifests name declared fields" do
    for {formatter, n} <- [
          snake_case: %{
            action: "action",
            input: "input",
            fields: "fields",
            success: "success",
            data: "data",
            palette: "palette",
            primary: "primary",
            secondary: "secondary",
            accent_color: "accent_color"
          },
          pascal_case: %{
            action: "Action",
            input: "input",
            fields: "Fields",
            success: "Success",
            data: "Data",
            palette: "Palette",
            primary: "Primary",
            secondary: "Secondary",
            accent_color: "AccentColor"
          }
        ] do
      manifest = ManifestBuilder.build(output_formatter: formatter)

      params = %{
        n.action => "create_project",
        n.input => %{
          n.palette => %{n.primary => "red", n.secondary => "blue", n.accent_color => "teal"}
        },
        n.fields => [%{n.palette => [n.accent_color]}]
      }

      assert run(params, manifest: manifest) == %{
               n.success => true,
               n.data => %{n.palette => %{n.accent_color => "teal"}}
             }
    end
  end

  test "error paths into declared fields use client names" do
    assert %{"type" => "unknown_map_field", "fields" => ["palette.nope"], "path" => ["palette"]} =
             error!(%{"action" => "list_projects", "fields" => [%{"palette" => ["nope"]}]})
  end
end
