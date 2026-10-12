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

defmodule AshRpc.Test.Calculations.FeaturedPost do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:post]

  @impl true
  def strict_loads?, do: false

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn
      %{post: %AshRpc.Test.Post{} = post} -> %Ash.Union{type: :post, value: post}
      _ -> nil
    end)
  end
end

defmodule AshRpc.Test.Calculations.ProjectSummary do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn _ ->
      %AshRpc.Test.ProjectStats{
        view_count: 42,
        edit_count: 7,
        all_done?: false,
        metrics: %{focus_seconds: 900, efficiency: 0.85}
      }
    end)
  end
end

defmodule AshRpc.Test.Calculations.ProjectReport do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    rows = [
      %AshRpc.Test.ProjectMeta{category: "work", priority_score: 80},
      %AshRpc.Test.ProjectMeta{category: "personal", priority_score: 20}
    ]

    Enum.map(records, fn _ -> %{rows: rows, total: 2} end)
  end
end

defmodule AshRpc.Test.Calculations.SelfRecords do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context), do: records
end

defmodule AshRpc.Test.Calculations.IsLate do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:due_date]

  @impl true
  def calculate(records, _opts, _context) do
    today = Date.utc_today()
    Enum.map(records, &(not is_nil(&1.due_date) and Date.compare(&1.due_date, today) == :lt))
  end
end

defmodule AshRpc.Test.Calculations.DaysLeft do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:due_date]

  @impl true
  def calculate(records, _opts, _context) do
    today = Date.utc_today()
    Enum.map(records, &(&1.due_date && Date.diff(&1.due_date, today)))
  end
end
