# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorProtocolTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Errors, Runtime}

  test "changeset and query Required share one impl" do
    expected = %{
      message: " title is required",
      short_message: "Required field",
      type: "required",
      vars: %{field: :title},
      fields: [:title],
      path: []
    }

    assert AshRpc.Error.to_error(Ash.Error.Changes.Required.exception(field: :title)) == expected
    assert AshRpc.Error.to_error(Ash.Error.Query.Required.exception(field: :title)) == expected
  end

  test "changeset and query InvalidArgument share one impl" do
    expected = %{
      message: "is bad",
      short_message: "Invalid argument",
      type: "invalid_argument",
      vars: %{field: :title},
      fields: [:title],
      path: []
    }

    for module <- [Ash.Error.Changes.InvalidArgument, Ash.Error.Query.InvalidArgument] do
      assert AshRpc.Error.to_error(module.exception(field: :title, message: "is bad")) == expected
    end
  end

  test "Ash.Error.to_error_class/1 is idempotent, so converting once is enough" do
    not_found = Ash.Error.Query.NotFound.exception(resource: AshRpc.Test.Post)

    for error <- [
          not_found,
          Ash.Error.Invalid.exception(errors: [not_found]),
          [not_found, Ash.Error.Changes.Required.exception(field: :title)],
          Reactor.Error.Invalid.RunStepError.exception(error: not_found, step: :step),
          %{some: :map}
        ] do
      once = Ash.Error.to_error_class(error)
      assert Ash.Error.to_error_class(once) == once
    end
  end

  defmodule RaisingError do
    use Splode.Error, fields: [], class: :invalid
    def message(_), do: "raising"
  end

  defmodule RaisingStruct do
    defstruct [:errors]
  end

  defimpl AshRpc.Error, for: RaisingError do
    def to_error(_), do: raise("impl failed")
  end

  defimpl AshRpc.Error, for: RaisingStruct do
    def to_error(_), do: raise("impl failed")
  end

  describe "a raising AshRpc.Error impl" do
    @tag :capture_log
    test "falls back to a generic error that keeps the exception's path" do
      error = RaisingError.exception(path: [:post, :title])

      assert [%{type: "error", message: "something went wrong", path: ["post", "title"]}] =
               Errors.to_errors(Runtime.new(AshRpc.Test.Profile), error)
    end
  end

  test "non-exception structs are wrapped as unknown errors and never reach an impl" do
    assert [%{type: "unknown_error", path: []}] =
             Errors.to_errors(Runtime.new(AshRpc.Test.Profile), %RaisingStruct{errors: nil})
  end
end
