# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorRedactionTest do
  @moduledoc """
  Error responses must never carry internal error terms or structs to the
  client. Unrecognised error terms are replaced by a generic error with an id,
  and the term itself is only logged server-side under that id.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AshRpc.ErrorBuilder

  @profile AshRpc.Test.Profile
  @secret "sk_live_123"

  setup do: %{rt: AshRpc.Runtime.new(@profile)}

  describe "unrecognised error terms" do
    for {label, term} <- [
          {"atom-tagged 2-tuple", {:internal_state, %{api_key: "sk_live_123"}}},
          {"untagged tuple", {:a, :b, %{api_key: "sk_live_123"}}},
          {"binary", "sk_live_123"},
          {"keyword list", [message: "is invalid", value: "sk_live_123"]}
        ] do
      test "#{label} is redacted from the client and logged with an error id", %{rt: rt} do
        {responses, log} =
          with_log(fn ->
            ErrorBuilder.build_error_response(rt, unquote(Macro.escape(term)))
          end)

        responses = List.wrap(responses)
        assert responses != []

        for response <- responses do
          refute inspect(response) =~ @secret
          assert response.type == "internal_error"
          assert is_binary(response.error_id)
          assert response.message =~ response.error_id
          assert log =~ response.error_id
        end

        assert log =~ @secret
      end
    end
  end

  describe "primitive return types" do
    test "field selection on a primitive return reports the type name, not the type struct" do
      result =
        AshRpc.run_action(@profile, %AshRpc.Context{}, %{
          "action" => "catalog_publication_date",
          "fields" => ["x"],
          "input" => %{}
        })

      assert result["success"] == false
      assert [%{"type" => "invalid_field_selection", "vars" => vars}] = result["errors"]
      assert vars["returnType"] == "Date"
      refute inspect(result) =~ "Ash.Info.Manifest"
    end

    test "a return type without a name is reported as unknown, not inspected", %{rt: rt} do
      type = %Ash.Info.Manifest.Type{kind: :any, constraints: [secret: @secret]}

      response =
        ErrorBuilder.build_error_response(
          rt,
          {:invalid_field_selection, :primitive_type, type, ["x"], []}
        )

      assert response.type == "invalid_field_selection"
      assert response.vars.return_type == "unknown"
      refute inspect(response) =~ @secret
    end
  end

  describe "invalid struct-typed arguments" do
    test "produce an invalid_argument error instead of inspected cast-error terms" do
      result =
        AshRpc.run_action(@profile, %AshRpc.Context{}, %{
          "action" => "catalog_assign",
          "fields" => ["assigneeId"],
          "input" => %{"assignee" => %{"id" => "not-a-uuid", "name" => "x"}}
        })

      assert result["success"] == false
      errors = result["errors"]
      assert errors != []

      for error <- errors do
        refute error["type"] in ["field_validation_error", "unknown_error", "internal_error"]
        refute Map.has_key?(error["details"] || %{}, "error")
      end

      assert [%{"type" => "invalid_argument", "path" => ["assignee"], "fields" => ["id"]}] =
               errors
    end
  end
end
