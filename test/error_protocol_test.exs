# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorProtocolTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Errors, Runtime}

  test "changeset and query Required share one impl" do
    expected = %{
      # Ash's Required message has a leading space when no field type is given.
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

  test "changeset, query and action InvalidArgument share one impl" do
    expected = %{
      message: "is bad",
      short_message: "Invalid argument",
      type: "invalid_argument",
      vars: %{field: :title},
      fields: [:title],
      path: []
    }

    for module <- [
          Ash.Error.Changes.InvalidArgument,
          Ash.Error.Query.InvalidArgument,
          Ash.Error.Action.InvalidArgument
        ] do
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

  describe "impl shapes" do
    test "InvalidChanges keeps its fields, vars and path" do
      error = %Ash.Error.Changes.InvalidChanges{
        fields: [:field1, :field2],
        vars: [key: "value"],
        path: [:data, :attributes]
      }

      assert AshRpc.Error.to_error(error) == %{
               message: "field1, field2: invalid",
               short_message: "Invalid changes",
               type: "invalid_changes",
               vars: %{key: "value"},
               fields: [:field1, :field2],
               path: [:data, :attributes]
             }
    end

    test "NoSuchInput is unknown_input naming the input as sent, with no path" do
      error =
        Ash.Error.Invalid.NoSuchInput.exception(
          resource: AshRpc.Test.Post,
          action: :set_viewed,
          input: "auditNote",
          inputs: [:is_viewed?],
          path: [0]
        )

      assert AshRpc.Error.to_error(error) == %{
               message: "Unknown input %{field}",
               short_message: "Unknown input",
               type: "unknown_input",
               vars: %{field: "auditNote"},
               fields: ["auditNote"],
               path: []
             }
    end

    test "NotFound has no fields" do
      error = %Ash.Error.Query.NotFound{vars: [], resource: AshRpc.Test.Post}

      assert AshRpc.Error.to_error(error) == %{
               message: "record not found",
               short_message: "Not found",
               type: "not_found",
               vars: %{},
               fields: [],
               path: []
             }
    end

    test "Required keeps the error's path" do
      error = %Ash.Error.Changes.Required{field: :email, vars: [], path: [:author, :profile]}

      assert %{path: [:author, :profile], fields: [:email]} = AshRpc.Error.to_error(error)
    end

    test "InvalidAttribute names its field and defaults the path to []" do
      assert AshRpc.Error.to_error(%Ash.Error.Changes.InvalidAttribute{field: :age, vars: []}) ==
               %{
                 message: "Invalid value provided for age.\n",
                 short_message: "Invalid attribute",
                 type: "invalid_attribute",
                 vars: %{field: :age},
                 fields: [:age],
                 path: []
               }
    end

    test "InvalidAttribute prefers its own message and keeps its path" do
      error =
        Ash.Error.Changes.InvalidAttribute.exception(
          field: :age,
          message: "must be positive",
          path: [:profile]
        )

      assert %{message: "must be positive", path: [:profile], fields: [:age]} =
               AshRpc.Error.to_error(error)
    end

    test "a Policy error built without facts is still a static forbidden" do
      assert AshRpc.Error.to_error(%Ash.Error.Forbidden.Policy{vars: []}) == %{
               message: "forbidden",
               short_message: "Forbidden",
               type: "forbidden",
               vars: %{},
               fields: [],
               path: []
             }
    end
  end

  describe "unwrapping" do
    test "an error class unwraps to its inner errors" do
      inner = %Ash.Error.Changes.Required{field: :title}

      assert Errors.unwrap_errors(%Ash.Error.Invalid{errors: [inner]}) == [inner]
    end

    test "nested error classes unwrap to the innermost error" do
      innermost = %Ash.Error.Changes.Required{field: :title}
      outer = %Ash.Error.Forbidden{errors: [%Ash.Error.Invalid{errors: [innermost]}]}

      assert Errors.unwrap_errors(outer) == [innermost]
    end

    test "a list of error classes unwraps to every inner error in order" do
      required = %Ash.Error.Changes.Required{field: :title}
      invalid = %Ash.Error.Changes.InvalidAttribute{field: :age}
      not_found = %Ash.Error.Query.NotFound{}

      assert Errors.unwrap_errors([
               %Ash.Error.Invalid{errors: [required, invalid]},
               not_found
             ]) == [required, invalid, not_found]
    end

    test "an error nested in Ash.Error.Invalid takes its own path, not the wrapper's" do
      wrapped = %Ash.Error.Invalid{
        class: :invalid,
        errors: [%Ash.Error.Changes.InvalidAttribute{field: :title, message: "is invalid"}],
        path: [:data, :attributes]
      }

      assert Errors.to_errors(Runtime.new(AshRpc.Test.Profile), wrapped) == [
               %{
                 message: "is invalid",
                 short_message: "Invalid attribute",
                 type: "invalid_attribute",
                 vars: %{field: "title"},
                 fields: ["title"],
                 path: []
               }
             ]
    end

    test "a RunStepError wrapping an error class is built from the inner error" do
      inner =
        Ash.Error.Changes.InvalidChanges.exception(message: "wrapped error")
        |> Ash.Error.to_error_class()

      error =
        Reactor.Error.Invalid.RunStepError.exception(
          error: inner,
          step: %Reactor.Step{name: :test_step}
        )

      assert AshRpc.ErrorBuilder.build_error_response(Runtime.new(AshRpc.Test.Profile), error) ==
               [
                 %{
                   message: "wrapped error",
                   short_message: "Invalid changes",
                   type: "invalid_changes",
                   vars: %{},
                   fields: [],
                   path: []
                 }
               ]
    end

    test "a RunStepError wrapping a plain exception is an unknown_error" do
      error =
        Reactor.Error.Invalid.RunStepError.exception(
          error: RuntimeError.exception("something unexpected"),
          step: %Reactor.Step{name: :test_step}
        )

      assert AshRpc.ErrorBuilder.build_error_response(Runtime.new(AshRpc.Test.Profile), error) ==
               [
                 %{
                   message: "Something went wrong",
                   short_message: "Unknown error",
                   type: "unknown_error",
                   vars: %{},
                   fields: [],
                   path: []
                 }
               ]
    end
  end

  describe "query, page, primary key and actor impls" do
    @impl_cases [
      {"InvalidQuery with a field",
       Ash.Error.Query.InvalidQuery.exception(field: :title, message: "bad query"),
       %{
         message: "bad query",
         short_message: "Invalid query",
         type: "invalid_query",
         vars: %{},
         fields: [:title],
         path: []
       }},
      {"InvalidQuery with fields",
       Ash.Error.Query.InvalidQuery.exception(fields: [:title, :body], message: "bad query"),
       %{
         message: "bad query",
         short_message: "Invalid query",
         type: "invalid_query",
         vars: %{},
         fields: [:title, :body],
         path: []
       }},
      {"InvalidKeyset with a key",
       Ash.Error.Page.InvalidKeyset.exception(value: "abc", key: :after),
       %{
         message: ~s(Invalid value provided as a keyset for after: "abc"),
         short_message: "Invalid keyset",
         type: "invalid_keyset",
         vars: %{},
         fields: [],
         path: []
       }},
      {"InvalidKeyset without a key", Ash.Error.Page.InvalidKeyset.exception(value: "abc"),
       %{
         message: ~s(Invalid value provided as a keyset: "abc"),
         short_message: "Invalid keyset",
         type: "invalid_keyset",
         vars: %{},
         fields: [],
         path: []
       }},
      {"InvalidPage", Ash.Error.Query.InvalidPage.exception(page: [limit: -1]),
       %{
         message: "[limit: -1] is not a valid page option",
         short_message: "Invalid pagination",
         type: "invalid_page",
         vars: %{},
         fields: [],
         path: []
       }},
      {"InvalidPrimaryKey",
       Ash.Error.Invalid.InvalidPrimaryKey.exception(resource: AshRpc.Test.Post, value: "nope"),
       %{
         message: ~s(invalid primary key "nope" provided),
         short_message: "Invalid primary key",
         type: "invalid_primary_key",
         vars: %{},
         fields: [],
         path: []
       }},
      {"ReadActionRequiresActor", Ash.Error.Query.ReadActionRequiresActor.exception([]),
       %{
         message: "actor is required",
         short_message: "Authentication required",
         type: "forbidden",
         vars: %{},
         fields: [],
         path: []
       }}
    ]

    for {label, error, expected} <- @impl_cases do
      @error error
      @expected expected

      test "#{label} has its own impl" do
        assert AshRpc.Error.impl_for(@error) == Module.concat(AshRpc.Error, @error.__struct__)
        assert AshRpc.Error.to_error(@error) == @expected
      end
    end

    test "an InvalidQuery without a message gets a static one, not the inspected struct" do
      error = Ash.Error.Query.InvalidQuery.exception(field: :title, value: "private value")

      assert AshRpc.Error.to_error(error).message == "Invalid query"
    end
  end

  test "DefaultErrorHandler returns errors unchanged, placeholders included" do
    for error <- [
          %{
            message: "Field %{field} must be at least %{min} characters",
            short_message: "Too short",
            vars: %{field: "password", min: 8},
            type: "validation_error"
          },
          %{message: "Field %{field} is invalid", short_message: "Invalid", vars: %{}},
          %{message: "Simple error message", short_message: "Error"}
        ] do
      assert AshRpc.DefaultErrorHandler.handle_error(error, %{}) == error
    end
  end
end
