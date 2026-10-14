# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ErrorsTest do
  use ExUnit.Case, async: true

  alias AshRpc.{Errors, Runtime}

  # Splode errors with a class survive Ash.Error.to_error_class/1 unwrapped;
  # plain exceptions would be wrapped in Ash.Error.Unknown.UnknownError.
  defmodule CustomError do
    use Splode.Error, fields: [:text], class: :invalid
    def message(error), do: error.text
  end

  defmodule NoImplError do
    use Splode.Error, fields: [], class: :invalid
    def message(_error), do: "kaboom"
  end

  defimpl AshRpc.Error, for: CustomError do
    def to_error(e),
      do: %{
        message: e.text,
        short_message: "Custom",
        type: "custom",
        vars: %{},
        fields: [],
        path: []
      }
  end

  defmodule DroppingProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def error_handler(_domain), do: {__MODULE__, :drop, []}
    def drop(_error, _context), do: nil
  end

  defmodule RaisingDetailProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def show_raised_errors?(AshRpc.Test.Domain), do: true
    def show_raised_errors?(_), do: false
  end

  defmodule BreakdownProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def show_policy_breakdowns?, do: true
    @impl AshRpc.Profile
    def error_handler(_domain), do: {__MODULE__, :tag, []}
    def tag(error, _context), do: Map.put(error, :seen_message, error.message)
  end

  defmodule NotifyingProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def error_handler(_domain), do: {__MODULE__, :notify, []}

    def notify(error, _context) do
      send(self(), {:profile_handler_called, error})
      error
    end
  end

  defmodule CustomHintProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def stale_client_hint, do: "Regenerate the client."
  end

  defmodule CustomSuggestionProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def action_not_found_suggestion, do: "Check the rpc block."
  end

  defmodule NoSuggestionProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def action_not_found_suggestion, do: nil
  end

  defmodule NoHintProfile do
    use AshRpc.Profile, manifest: AshRpc.Test.ManifestBuilder
    @impl AshRpc.Profile
    def stale_client_hint, do: nil
  end

  defmodule DroppingResource do
    def handle_rpc_error(_error, _context), do: nil
  end

  defp policy_error do
    Ash.Error.Forbidden.Policy.exception(
      resource: AshRpc.Test.Post,
      action: :read,
      policies: [
        %Ash.Policy.Policy{
          description: "Only admins can read",
          condition: [{Ash.Policy.Check.Expression, [expr: true]}],
          policies: [],
          bypass?: false,
          access_type: :strict
        }
      ],
      facts: %{{Ash.Policy.Check.Expression, [expr: true]} => true},
      must_pass_strict_check?: false
    )
  end

  test "custom AshRpc.Error impls are used" do
    [error] =
      Errors.to_errors(Runtime.new(AshRpc.Test.Profile), CustomError.exception(text: "boom"))

    assert error.type == "custom"
  end

  test "a handler returning nil drops the error" do
    assert Errors.to_errors(
             Runtime.new(DroppingProfile),
             CustomError.exception(text: "boom"),
             AshRpc.Test.Domain
           ) == []
  end

  test "an error dropped by the resource handler skips the profile handler" do
    assert Errors.to_errors(
             Runtime.new(NotifyingProfile),
             CustomError.exception(text: "boom"),
             AshRpc.Test.Domain,
             DroppingResource
           ) == []

    refute_received {:profile_handler_called, _}
  end

  test "unknown fields on non-resource types name the type kind" do
    rt = Runtime.new(AshRpc.Test.Profile)

    assert %{type: "unknown_field", vars: %{kind: "tuple"}, fields: ["stats.nope"]} =
             AshRpc.ErrorBuilder.build_error_response(
               rt,
               {:unknown_field, :nope, "tuple", [:stats]}
             )

    assert %{vars: %{kind: "field constrained"}} =
             AshRpc.ErrorBuilder.build_error_response(
               rt,
               {:unknown_field, :nope, "field_constrained_type", []}
             )
  end

  describe "action_not_found suggestion" do
    defp suggestion_details(profile),
      do:
        AshRpc.ErrorBuilder.build_error_response(Runtime.new(profile), {:action_not_found, "x"}).details

    test "defaults to the client-neutral suggestion" do
      assert suggestion_details(AshRpc.Test.Profile).suggestion ==
               AshRpc.Profile.default_action_not_found_suggestion()
    end

    test "comes from the profile" do
      assert suggestion_details(CustomSuggestionProfile).suggestion == "Check the rpc block."
    end

    test "is omitted when the profile returns nil" do
      refute Map.has_key?(suggestion_details(NoSuggestionProfile), :suggestion)
    end
  end

  describe "stale client hint" do
    defp build(profile, error),
      do: AshRpc.ErrorBuilder.build_error_response(Runtime.new(profile), error)

    test "comes from the profile on errors a stale client can cause" do
      assert build(AshRpc.Test.Profile, {:action_not_found, "x"}).details.hint ==
               AshRpc.Profile.default_stale_client_hint()

      assert build(CustomHintProfile, {:load_denied, ["secret"]}).details.hint ==
               "Regenerate the client."
    end

    test "is omitted when the profile returns nil" do
      refute Map.has_key?(build(NoHintProfile, {:action_not_found, "x"}).details, :hint)
    end

    test "is omitted on malformed requests a generated client never sends" do
      for error <- [
            {:invalid_input_format, "x"},
            {:invalid_pagination, "x"},
            {:invalid_fields_type, "x"}
          ] do
        refute Map.has_key?(build(CustomHintProfile, error).details, :hint)
      end
    end
  end

  @tag :capture_log
  test "show_raised_errors? exposes the exception message for that domain only" do
    rt = Runtime.new(RaisingDetailProfile)
    error = NoImplError.exception(path: [:post])

    assert Errors.to_errors(rt, error, AshRpc.Test.Domain) == [
             %{
               message: "kaboom",
               short_message: "NoImplError",
               type: "no_impl_error",
               vars: %{},
               fields: [],
               path: ["post"]
             }
           ]

    assert [%{type: "internal_error"}] = Errors.to_errors(rt, error, nil)
  end

  test "policy errors are 'forbidden' unless the profile shows breakdowns" do
    assert [%{message: "forbidden"}] =
             Errors.to_errors(Runtime.new(AshRpc.Test.Profile), policy_error())

    [error] = Errors.to_errors(Runtime.new(BreakdownProfile), policy_error(), AshRpc.Test.Domain)
    assert error.message =~ "Policy Breakdown"
    assert error.message =~ "Only admins can read"
    assert error.seen_message == error.message
    assert error.short_message == "Forbidden"
    assert error.type == "forbidden"
  end

  test "the protocol impl itself never leaks a breakdown" do
    assert AshRpc.Error.to_error(policy_error()).message == "forbidden"
  end

  describe "error handler failures fail closed" do
    @secret "search backend unreachable at es.internal:9200 (token=S3cr3t-Pr0d-Pw)"

    defp handle(profile, error),
      do: Errors.to_errors(Runtime.new(profile), error, AshRpc.Test.Domain)

    defp secret_error,
      do: Ash.Error.Query.InvalidArgument.exception(field: :filter, message: @secret)

    defp assert_fails_closed(response) do
      assert response.type == "internal_error"
      assert response.short_message == "Internal error"
      assert is_binary(response.error_id)
      assert response.vars == %{}
      assert response.fields == []
      refute String.contains?(response.message, "S3cr3t-Pr0d-Pw")
      refute String.contains?(response.message, "es.internal")
      refute inspect(response) =~ "S3cr3t-Pr0d-Pw"
      refute inspect(response) =~ "es.internal"
    end

    test "an error class the handler matches is redacted" do
      error = Ash.Error.Changes.InvalidAttribute.exception(field: :email, message: @secret)

      [response] = handle(AshRpc.Test.PartialHandlerProfile, error)

      assert response.message == "Invalid value."
      refute String.contains?(response.message, "S3cr3t-Pr0d-Pw")
      refute inspect(response) =~ "S3cr3t-Pr0d-Pw"
    end

    @tag capture_log: true
    test "an error class the handler has no clause for returns a generic error, not the raw one" do
      [response] = handle(AshRpc.Test.PartialHandlerProfile, secret_error())

      assert_fails_closed(response)
    end

    @tag capture_log: true
    test "a handler that raises returns a generic error, not the raw one" do
      [response] = handle(AshRpc.Test.RaisingHandlerProfile, secret_error())

      assert_fails_closed(response)
    end

    @tag capture_log: true
    test "a handler that throws is treated the same as one that raises" do
      [response] = handle(AshRpc.Test.ThrowingHandlerProfile, secret_error())

      assert_fails_closed(response)
    end

    @tag capture_log: true
    test "a raising handler fails closed on the wire" do
      params = %{"action" => "create_post", "input" => %{}, "fields" => ["id"]}

      assert %{"success" => false, "errors" => [_ | _] = errors} =
               AshRpc.run_action(AshRpc.Test.RaisingHandlerProfile, %AshRpc.Context{}, params)

      for error <- errors do
        assert %{"type" => "internal_error", "errorId" => error_id} = error
        assert is_binary(error_id)
        assert error["message"] =~ error_id
        assert error["fields"] == []
        refute inspect(error) =~ "title is required"
      end
    end
  end

  describe "to_errors" do
    test "a single error is formatted for the client" do
      # Ash's Required message has a leading space when no field type is given.
      assert Errors.to_errors(
               Runtime.new(AshRpc.Test.Profile),
               %Ash.Error.Changes.Required{field: :email}
             ) == [
               %{
                 message: " email is required",
                 short_message: "Required field",
                 type: "required",
                 vars: %{field: "email"},
                 fields: ["email"],
                 path: []
               }
             ]
    end

    test "bread crumbs never reach the client message" do
      error = %Ash.Error.Changes.Required{
        field: :email,
        type: :argument,
        bread_crumbs: ["Returned from bulk update: AshRpc.Test.Post.update"]
      }

      assert [%{message: "argument email is required"}] =
               Errors.to_errors(Runtime.new(AshRpc.Test.Profile), error)
    end

    test "a plain exception becomes unknown_error without its message" do
      assert Errors.to_errors(
               Runtime.new(AshRpc.Test.Profile),
               %RuntimeError{message: "database password is hunter2"}
             ) == [
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

    test "a missing tenant is tenant_required, not internal_error" do
      error = Ash.Error.Invalid.TenantRequired.exception(resource: AshRpc.Test.Post)

      assert Errors.to_errors(Runtime.new(AshRpc.Test.Profile), error) == [
               %{
                 message:
                   "Queries against the AshRpc.Test.Post resource require a tenant to be specified",
                 short_message: "Tenant required",
                 type: "tenant_required",
                 vars: %{},
                 fields: [],
                 path: []
               }
             ]
    end
  end

  describe "lists of error classes" do
    test "every inner error of every class becomes one error, in order" do
      errors = [
        %Ash.Error.Invalid{
          class: :invalid,
          errors: [
            %Ash.Error.Changes.Required{field: :title},
            %Ash.Error.Changes.InvalidAttribute{field: :age}
          ]
        },
        %Ash.Error.Invalid{class: :invalid, errors: [%Ash.Error.Changes.Required{field: :email}]},
        %Ash.Error.Query.NotFound{}
      ]

      # Ash's Required message has a leading space when no field type is given.
      assert build(AshRpc.Test.Profile, errors) == [
               %{
                 message: " title is required",
                 short_message: "Required field",
                 type: "required",
                 vars: %{field: "title"},
                 fields: ["title"],
                 path: []
               },
               %{
                 message: "Invalid value provided for age.\n",
                 short_message: "Invalid attribute",
                 type: "invalid_attribute",
                 vars: %{field: "age"},
                 fields: ["age"],
                 path: []
               },
               %{
                 message: " email is required",
                 short_message: "Required field",
                 type: "required",
                 vars: %{field: "email"},
                 fields: ["email"],
                 path: []
               },
               %{
                 message: "record not found",
                 short_message: "Not found",
                 type: "not_found",
                 vars: %{},
                 fields: [],
                 path: []
               }
             ]
    end

    test "an empty list gives no errors" do
      assert build(AshRpc.Test.Profile, []) == []
    end
  end

  describe "fallback for errors without an impl" do
    @tag :capture_log
    test "is internal_error with an error_id and the exception's path" do
      [response] =
        Errors.to_errors(
          Runtime.new(AshRpc.Test.Profile),
          NoImplError.exception(path: [:post, :title])
        )

      assert %{error_id: error_id} = response
      assert is_binary(error_id)

      assert response == %{
               message: "Something went wrong. Unique error id: #{error_id}",
               short_message: "Internal error",
               type: "internal_error",
               vars: %{},
               fields: [],
               path: ["post", "title"],
               error_id: error_id
             }
    end
  end
end
