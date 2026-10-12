# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ResultProcessorTest do
  use ExUnit.Case, async: true

  alias AshRpc.{ResultProcessor, Runtime}

  setup do
    %{runtime: Runtime.new(AshRpc.Test.Profile)}
  end

  test "normalize_value_for_json/2 makes untyped values JSON-encodable", %{runtime: rt} do
    assert ResultProcessor.normalize_value_for_json([priority: 8, tags: []], rt) ==
             %{"priority" => 8, "tags" => []}

    assert ResultProcessor.normalize_value_for_json(Duration.new!(hour: 1), rt) == "PT1H"
  end

  describe "empty arrays and keyword lists" do
    test "an empty array nested inside a map stays an array", %{runtime: rt} do
      data = %{
        id: "123",
        title: "First post",
        tags: [],
        metadata: %{items: [], config: %{flags: []}}
      }

      assert ResultProcessor.normalize_value_for_json(data, rt) == %{
               id: "123",
               title: "First post",
               tags: [],
               metadata: %{items: [], config: %{flags: []}}
             }
    end

    test "empty arrays inside a list stay arrays", %{runtime: rt} do
      assert ResultProcessor.normalize_value_for_json([[], [1, 2], [], [3]], rt) ==
               [[], [1, 2], [], [3]]
    end

    test "an empty array field passes through an extraction template", %{runtime: rt} do
      data = %{id: "123", items: []}

      assert ResultProcessor.process(data, [:id, :items], nil, rt) == %{id: "123", items: []}
    end

    test "a mixed list containing tuples is kept as a list", %{runtime: rt} do
      mixed_list = [{:key, "value"}, "not_tuple", 42]

      assert ResultProcessor.normalize_value_for_json(mixed_list, rt) ==
               [{:key, "value"}, "not_tuple", 42]
    end

    test "a nested keyword list becomes a map", %{runtime: rt} do
      keyword_list = [
        priority: 5,
        metadata: %{created_by: "user", tags: ["urgent", "work"]},
        flags: [active: true, visible: false]
      ]

      assert ResultProcessor.normalize_value_for_json(keyword_list, rt) == %{
               "priority" => 5,
               "metadata" => %{created_by: "user", tags: ["urgent", "work"]},
               "flags" => %{"active" => true, "visible" => false}
             }
    end

    test "a keyword list value passes through an extraction template", %{runtime: rt} do
      data = %{
        id: "123",
        title: "First post",
        options: [priority: 7, category: "news", notify: false]
      }

      assert ResultProcessor.process(data, [:id, :title, :options], nil, rt) == %{
               id: "123",
               title: "First post",
               options: %{"priority" => 7, "category" => "news", "notify" => false}
             }
    end
  end

  describe "struct field filtering" do
    alias AshRpc.Test.Account

    defp account(attrs) do
      struct(Account, Map.put_new(attrs, :id, Ash.UUID.generate()))
    end

    defp refute_leaked(result, secrets) do
      inspected = inspect(result)
      Enum.each(secrets, fn secret -> refute inspected =~ secret end)
    end

    test "a bare resource struct is reduced to its public attributes", %{runtime: rt} do
      value =
        account(%{
          handle: "test-account",
          email: "test@example.com",
          secret: "secret_value",
          internal_notes: "internal_notes_value"
        })

      result = ResultProcessor.normalize_value_for_json(value, rt)

      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :handle)
      assert Map.has_key?(result, :email)
      refute Map.has_key?(result, :secret)
      refute Map.has_key?(result, :internal_notes)
      refute_leaked(result, ["secret_value", "internal_notes_value"])
    end

    test "an extraction template on a resource struct keeps only the selected field",
         %{runtime: rt} do
      value =
        account(%{
          handle: "test-account",
          email: "test@example.com",
          secret: "secret_value",
          internal_notes: "internal_notes_value"
        })

      result = ResultProcessor.process(value, [:handle], Account, rt)

      assert Map.has_key?(result, :handle)
      refute Map.has_key?(result, :id)
      refute Map.has_key?(result, :email)
      refute Map.has_key?(result, :secret)
      refute Map.has_key?(result, :internal_notes)
      refute_leaked(result, ["secret_value", "internal_notes_value"])
    end

    test "a resource struct nested in a map is reduced to its public attributes",
         %{runtime: rt} do
      record = %{
        id: Ash.UUID.generate(),
        handle: "main-account",
        email: "main@example.com",
        self_struct:
          account(%{
            handle: "nested-account",
            email: "nested@example.com",
            secret: "nested_secret",
            internal_notes: "nested_notes"
          })
      }

      result = ResultProcessor.process(record, [:id, :handle, :email, :self_struct], Account, rt)

      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :handle)
      assert Map.has_key?(result, :email)

      assert is_map(result[:self_struct])
      assert Map.has_key?(result[:self_struct], :id)
      assert Map.has_key?(result[:self_struct], :handle)
      assert Map.has_key?(result[:self_struct], :email)
      refute Map.has_key?(result[:self_struct], :secret)
      refute Map.has_key?(result[:self_struct], :internal_notes)
      refute_leaked(result, ["nested_secret", "nested_notes"])
    end

    test "a nested template on a nested resource struct keeps only the selected field",
         %{runtime: rt} do
      record = %{
        id: Ash.UUID.generate(),
        handle: "main-account",
        self_struct:
          account(%{
            handle: "nested-account",
            email: "nested@example.com",
            secret: "nested_secret",
            internal_notes: "nested_notes"
          })
      }

      result =
        ResultProcessor.process(record, [:id, :handle, {:self_struct, [:handle]}], Account, rt)

      assert Map.has_key?(result, :id)
      assert Map.has_key?(result, :handle)

      assert is_map(result[:self_struct])
      assert Map.has_key?(result[:self_struct], :handle)
      refute Map.has_key?(result[:self_struct], :id)
      refute Map.has_key?(result[:self_struct], :email)
      refute Map.has_key?(result[:self_struct], :secret)
      refute Map.has_key?(result[:self_struct], :internal_notes)
      refute_leaked(result, ["nested@example.com", "nested_secret", "nested_notes"])
    end

    test "each resource struct in an array is reduced to its public attributes",
         %{runtime: rt} do
      values = [
        account(%{
          handle: "account-1",
          email: "account1@example.com",
          secret: "secret1",
          internal_notes: "notes1"
        }),
        account(%{
          handle: "account-2",
          email: "account2@example.com",
          secret: "secret2",
          internal_notes: "notes2"
        })
      ]

      result = ResultProcessor.process(values, [], Account, rt)

      assert length(result) == 2

      Enum.each(result, fn item ->
        assert Map.has_key?(item, :id)
        assert Map.has_key?(item, :handle)
        assert Map.has_key?(item, :email)
        refute Map.has_key?(item, :secret)
        refute Map.has_key?(item, :internal_notes)
      end)

      refute_leaked(result, ["secret1", "secret2", "notes1", "notes2"])
    end

    test "an extraction template applies to each resource struct in an array",
         %{runtime: rt} do
      values = [
        account(%{
          handle: "account-1",
          email: "account1@example.com",
          secret: "secret1",
          internal_notes: "notes1"
        })
      ]

      result = ResultProcessor.process(values, [:handle], Account, rt)

      assert length(result) == 1
      [item] = result

      assert Map.has_key?(item, :handle)
      refute Map.has_key?(item, :id)
      refute Map.has_key?(item, :email)
      refute Map.has_key?(item, :secret)
      refute Map.has_key?(item, :internal_notes)
      refute_leaked(result, ["secret1", "notes1"])
    end
  end
end
