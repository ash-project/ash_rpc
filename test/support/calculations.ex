# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Test.Calculations.Excerpt do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:title]

  @impl true
  def calculate(records, _opts, context) do
    Enum.map(records, &String.slice(&1.title, 0, context.arguments.length))
  end
end

defmodule AshRpc.Test.Calculations.ScoredStats do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:view_count]

  @impl true
  def calculate(records, _opts, context) do
    boost = context.arguments.boost

    Enum.map(records, fn record ->
      %{word_count_1: (record.view_count || 0) + boost, is_featured?: boost > 0}
    end)
  end
end

defmodule AshRpc.Test.Calculations.SelfPost do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context), do: records
end
