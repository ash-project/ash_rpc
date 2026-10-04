# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.ErrorCases do
  @moduledoc false
  # One representative reason per AshRpc.ErrorBuilder clause, keyed by a stable label.
  # Used by the golden test; regenerate the snapshot only for intentional wire changes.

  @integer_type %Ash.Info.Manifest.Type{kind: :integer, name: "Integer", module: Ash.Type.Integer}

  def cases do
    not_found = Ash.Error.Query.NotFound.exception(resource: AshRpc.Test.Post)

    [
      {"action_not_found", {:action_not_found, "list_postz"}},
      {"unknown_map_field", {:unknown_field, :word_count, "map", [:post_stats]}},
      {"unknown_union_field", {:unknown_field, :text_member, "union_attribute", [:content]}},
      {"unknown_field_kind", {:unknown_field, :nope, "field_constrained_type", [:post_stats]}},
      {"unknown_field_resource", {:unknown_field, :user_name, AshRpc.Test.Post, [:author]}},
      {"calculation_requires_args", {:calculation_requires_args, :full_name, [:author]}},
      {"invalid_field_format", {:invalid_field_format, %{"self" => %{"args" => %{}}}, [:author]}},
      {"invalid_calculation_args", {:invalid_calculation_args, :full_name, []}},
      {"requires_field_selection", {:requires_field_selection, :relationship, :author, [:post]}},
      # After Task 3.6 the top-level form carries `[]` instead of `nil`; 3.6 keeps that
      # clause's body, so the snapshot entry below is unchanged.
      {"requires_field_selection_pathless",
       {:requires_field_selection, :field_constrained_type, []}},
      {"invalid_field_selection", {:invalid_field_selection, :view_count, :attribute, [:post]}},
      {"invalid_field_selection_primitive",
       {:invalid_field_selection, :primitive_type, @integer_type, ["x"], []}},
      {"invalid_field_selection_primitive_nil",
       {:invalid_field_selection, :primitive_type, nil, ["x"], [:post]}},
      {"field_does_not_support_nesting", {:field_does_not_support_nesting, :title, [:post]}},
      {"duplicate_field", {:duplicate_field, :view_count, [:post]}},
      {"unsupported_field_combination",
       {:unsupported_field_combination, :relationship, :author, "spec", []}},
      {"invalid_fields_type", {:invalid_fields_type, "title"}},
      {"invalid_union_input_not_a_map", {:invalid_union_input, :not_a_map}},
      {"invalid_union_input_no_member_key",
       {:invalid_union_input, :no_member_key, ["text", "number"]}},
      {"invalid_union_input_multiple_member_keys",
       {:invalid_union_input, :multiple_member_keys, ["text", "number"], ["text", "number"]}},
      {"missing_required_parameter", {:missing_required_parameter, :action}},
      {"missing_get_by_fields", {:missing_get_by_fields, ["title"]}},
      {"unexpected_get_by_fields", {:unexpected_get_by_fields, ["viewCount"], ["title"]}},
      {"empty_fields_array", {:empty_fields_array, []}},
      {"load_not_allowed", {:load_not_allowed, ["author.posts"]}},
      {"load_denied", {:load_denied, ["secret"]}},
      {"invalid_input_format", {:invalid_input_format, "x"}},
      {"unknown_page_keys", {:unknown_page_keys, ["page_size"]}},
      {"invalid_pagination", {:invalid_pagination, "x"}},
      {"invalid_identity_keys",
       {:invalid_identity, %{provided_keys: ["slug"], expected_keys: ["id"]}}},
      {"invalid_identity_message", {:invalid_identity, %{message: "bad identity"}}},
      {"invalid_get_by", {:invalid_get_by, %{message: "bad get_by"}}},
      {"missing_identity_primary_key",
       {:missing_identity, %{expected_keys: ["id"], identities: [:_primary_key]}}},
      {"missing_identity_many",
       {:missing_identity, %{expected_keys: ["id", "slug"], identities: [:_primary_key, :slug]}}},
      {"query_opts_on_non_relationship",
       {:query_opts_on_non_relationship, :title, :attribute, [:posts]}},
      {"query_opts_on_to_one", {:query_opts_on_to_one, :author, []}},
      {"args_and_query_opts_combined", {:args_and_query_opts_combined, :posts, []}},
      {"page_and_limit_offset_combined", {:page_and_limit_offset_combined, :posts, []}},
      {"nested_pagination_not_supported", {:nested_pagination_not_supported, :posts, []}},
      {"filter_not_supported_top_level", {:filter_not_supported, :top_level, :disabled}},
      {"filter_not_supported_nested", {:filter_not_supported, :posts, :disabled, [:author]}},
      {"sort_not_supported_top_level", {:sort_not_supported, :top_level, :unsupported}},
      {"sort_not_supported_nested", {:sort_not_supported, :posts, :disabled, [:author]}},
      {"pagination_not_supported_top_level",
       {:pagination_not_supported, :top_level, :unsupported}},
      {"invalid_nested_page", {:invalid_nested_page, :posts, {:unknown_keys, ["x"]}, []}},
      {"invalid_field_type", {:invalid_field_type, :user_name, [:author]}},
      {"field_validation_error", {:some_validation_failure, :x}},
      {"unknown_error", "boom"},
      {"ash_exception", not_found},
      {"ash_error_class", Ash.Error.Invalid.exception(errors: [not_found])},
      {"list", [{:action_not_found, "a"}, not_found]},
      {"reactor_run_step_error",
       Reactor.Error.Invalid.RunStepError.exception(error: not_found, step: :step)}
    ]
  end
end
