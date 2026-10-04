# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.MappingSource do
  @moduledoc false
  @behaviour AshRpc.MappingSource

  @exposed [AshRpc.Test.Author, AshRpc.Test.Post, AshRpc.Test.PostSettings]

  @impl true
  def input_formatter, do: :camel_case

  @impl true
  def output_formatter, do: :camel_case

  @impl true
  def exposed_resource?(resource), do: resource in @exposed

  @impl true
  def field_names(AshRpc.Test.Author), do: %{is_active?: "isActive"}
  def field_names(_resource), do: %{}

  @impl true
  def argument_names(AshRpc.Test.Post, :word_count), do: %{text: "body"}
  def argument_names(_resource, _action), do: %{}

  @impl true
  def type_field_names(AshRpc.Test.PostStats),
    do: %{word_count_1: "wordCount1", is_featured?: "isFeatured"}

  def type_field_names(_type), do: nil

  @impl true
  def entrypoint(%Ash.Info.Manifest.Entrypoint{config: %{ash_rpc_test: %{name: name}}} = e) do
    %AshRpc.Entrypoint{
      name: name,
      domain: AshRpc.Test.Domain,
      resource: e.resource,
      action: e.action.name
    }
  end

  def entrypoint(_entrypoint), do: nil
end
