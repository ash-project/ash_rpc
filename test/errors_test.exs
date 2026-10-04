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
    error = NoImplError.exception([])

    assert [%{message: "kaboom"}] = Errors.to_errors(rt, error, AshRpc.Test.Domain)
    assert [%{type: "internal_error"}] = Errors.to_errors(rt, error, nil)
  end

  test "policy errors are 'forbidden' unless the profile shows breakdowns" do
    assert [%{message: "forbidden"}] =
             Errors.to_errors(Runtime.new(AshRpc.Test.Profile), policy_error())

    [error] = Errors.to_errors(Runtime.new(BreakdownProfile), policy_error(), AshRpc.Test.Domain)
    assert error.message =~ "Only admins can read"
    assert error.seen_message == error.message
  end

  test "the protocol impl itself never leaks a breakdown" do
    assert AshRpc.Error.to_error(policy_error()).message == "forbidden"
  end
end
