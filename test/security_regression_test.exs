# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.SecurityRegressionTest do
  use ExUnit.Case, async: true

  alias AshRpc.ResultProcessor
  alias AshRpc.Test.{Post, PostSettings}

  @secret "123-45-6789"

  setup do
    %{runtime: AshRpc.Runtime.new(AshRpc.Test.Profile)}
  end

  defp forbidden(field) do
    %Ash.ForbiddenField{field: field, type: :attribute, original_value: @secret}
  end

  defp refute_leak(result) do
    encoded = Jason.encode!(result)
    refute String.contains?(encoded, @secret)
    refute String.contains?(encoded, "original_value")
    refute String.contains?(inspect(result), @secret)
  end

  describe "ForbiddenField redaction in results" do
    test "normalize_value_for_json redacts a ForbiddenField", %{runtime: rt} do
      result = ResultProcessor.normalize_value_for_json(forbidden(:title), rt)

      refute_leak(result)
    end

    test "a resource struct with a ForbiddenField field does not leak original_value",
         %{runtime: rt} do
      post = struct(Post, %{title: forbidden(:title), view_count: 3})

      refute_leak(ResultProcessor.process(post, [], Post, rt))
      refute_leak(ResultProcessor.process(post, [:title, :view_count], Post, rt))
    end

    test "a ForbiddenField inside an embedded struct does not leak original_value",
         %{runtime: rt} do
      settings = %PostSettings{theme_name: forbidden(:theme_name), allow_comments: true}
      post = struct(Post, %{title: "visible", settings: settings})

      refute_leak(ResultProcessor.process(post, [], Post, rt))

      refute_leak(ResultProcessor.process(post, [:title, {:settings, [:theme_name]}], Post, rt))

      refute_leak(ResultProcessor.normalize_value_for_json(settings, rt))
    end
  end

  describe "error payload serialization" do
    defmodule InternalConfig do
      defstruct [:name, :db_host, :api_key]
    end

    defp serialized_vars(runtime, vars) do
      error =
        Ash.Error.Changes.InvalidChanges.exception(
          fields: [:amount],
          message: "bad",
          vars: vars
        )

      [response] = AshRpc.Errors.to_errors(runtime, error)
      Jason.encode!(response)
      response.vars
    end

    @tag capture_log: true
    test "unknown structs are reduced to their module name, not unwrapped", %{runtime: rt} do
      config = %InternalConfig{
        name: "standard",
        db_host: "postgres://admin@10.0.0.5:5432/prod",
        api_key: "sk_live_SUPER_SECRET"
      }

      vars = serialized_vars(rt, rule: config)

      assert vars.rule == "#AshRpc.SecurityRegressionTest.InternalConfig<>"
      refute String.contains?(Jason.encode!(vars), "sk_live_SUPER_SECRET")
      refute String.contains?(Jason.encode!(vars), "10.0.0.5")
    end

    @tag capture_log: true
    test "Ash.ForbiddenField keeps its original_value hidden", %{runtime: rt} do
      vars = serialized_vars(rt, value: forbidden(:title))

      refute String.contains?(Jason.encode!(vars), @secret)
      refute String.contains?(inspect(vars), @secret)
    end

    test "value structs serialize to their natural representation", %{runtime: rt} do
      vars = serialized_vars(rt, max: Decimal.new("100.5"), name: Ash.CiString.new("Fred"))

      assert vars.max == "100.5"
      assert vars.name == "Fred"
    end

    @tag capture_log: true
    test "pids, references and functions do not leak identifiers", %{runtime: rt} do
      vars = serialized_vars(rt, pid: self(), ref: make_ref(), fun: &Enum.count/1)

      assert vars.pid == "#PID<>"
      assert vars.ref == "#Reference<>"
      assert vars.fun == "#Function<>"
    end
  end
end
