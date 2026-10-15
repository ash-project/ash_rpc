# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.RuntimeBoundaryTest do
  @moduledoc """
  Keeps runtime code reading action, resource and type shape from the decorated
  manifest (`AshRpc.Runtime` lookups) instead of from Ash or the app env: no
  `Ash.Resource.Info` or `Ash.DataLayer` calls and no `Application` env reads
  under `lib/ash_rpc/` and `lib/ash_rpc.ex`, apart from `@allowed`. Source files
  are parsed and walked as ASTs, so docs and comments that name these modules
  don't count, and calls through an `alias` do.
  """
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)

  # Files that are not runtime code.
  @excluded [
    # Runs once at decoration time, which is where reading Ash belongs.
    "lib/ash_rpc/manifest/decorator.ex"
  ]

  # {file, module, function, arity} calls that runtime code may make.
  @allowed [
    # Classifies a runtime value's struct module, not action shape.
    {"lib/ash_rpc/introspection.ex", Ash.Resource.Info, :resource?, 1},
    # Classifies a runtime value's struct module, not action shape.
    {"lib/ash_rpc/introspection.ex", Ash.Resource.Info, :embedded?, 1},
    # Fallback when the resource lookup has no precomputed bulk-authorize strategy.
    {"lib/ash_rpc/pipeline.ex", Ash.DataLayer, :data_layer_can?, 2}
  ]

  @app_env_funs [:get_env, :fetch_env, :fetch_env!, :get_all_env]

  test "runtime code makes no Ash introspection, data layer or app env calls" do
    violations =
      for file <- runtime_files(),
          {module, fun, arity, line} <- forbidden_calls(File.read!(Path.join(@root, file))),
          {file, module, fun, arity} not in @allowed do
        "#{file}:#{line} #{inspect(module)}.#{fun}/#{arity}"
      end

    assert violations == [],
           failure(
             "Runtime calls that bypass the manifest (use AshRpc.Runtime lookups)",
             violations
           )
  end

  test "every allowlist entry matches a call in its file" do
    calls =
      for file <- runtime_files(),
          {module, fun, arity, _line} <- forbidden_calls(File.read!(Path.join(@root, file))),
          into: MapSet.new(),
          do: {file, module, fun, arity}

    stale =
      for {file, module, fun, arity} = entry <- @allowed,
          entry not in calls do
        "#{file} #{inspect(module)}.#{fun}/#{arity}"
      end

    assert stale == [], failure("Allowlist entries with no matching call", stale)
  end

  test "the walker finds direct, aliased and captured calls but not docs or comments" do
    source = ~S'''
    defmodule Example do
      @moduledoc "Use lookups instead of `Ash.Resource.Info.action/2`."
      alias Ash.Resource.Info
      alias Ash.Resource.Info, as: ResInfo, warn: false
      alias Ash.{DataLayer}

      # Ash.Resource.Info.attributes(resource)
      def a(r), do: Ash.Resource.Info.action(r, :read)
      def b(r), do: Info.attributes(r)
      def c(r), do: ResInfo.relationship(r, :items)
      def d(r), do: DataLayer.data_layer(r)
      def e, do: Application.get_env(:app, :key)
      def f, do: &Ash.Resource.Info.public_fields/1
      def g, do: Application.put_env(:app, :key, 1)
      def h(r), do: Ash.Resource.Info.Other.thing(r)
      def i(r), do: r |> Ash.Resource.Info.resource?() |> Application.get_env(:key)
    end
    '''

    assert source |> forbidden_calls() |> Enum.sort_by(&elem(&1, 3)) == [
             {Ash.Resource.Info, :action, 2, 8},
             {Ash.Resource.Info, :attributes, 1, 9},
             {Ash.Resource.Info, :relationship, 2, 10},
             {Ash.DataLayer, :data_layer, 1, 11},
             {Application, :get_env, 2, 12},
             {Ash.Resource.Info, :public_fields, 1, 13},
             {Application, :get_env, 2, 16},
             {Ash.Resource.Info, :resource?, 1, 16}
           ]
  end

  defp runtime_files do
    ["lib/ash_rpc.ex" | Path.wildcard(Path.join(@root, "lib/ash_rpc/**/*.ex"))]
    |> Enum.map(&Path.relative_to(&1, @root))
    |> Enum.reject(&(&1 in @excluded))
  end

  # Forbidden remote calls in `source`, as {module, function, arity, line}.
  defp forbidden_calls(source) do
    ast = Code.string_to_quoted!(source, columns: false)
    aliases = collect_aliases(ast)

    {_, calls} =
      Macro.prewalk(ast, [], fn
        {:&, _, [{:/, _, [{{:., meta, [mod, fun]}, _, _}, arity]}]}, acc when is_integer(arity) ->
          {nil, record(acc, expand(mod, aliases), fun, arity, meta)}

        # The piped value is the call's first argument.
        {:|>, _, [left, {{:., meta, [mod, fun]}, _, args}]}, acc
        when is_atom(fun) and is_list(args) ->
          {{:__block__, [], [left]},
           record(acc, expand(mod, aliases), fun, length(args) + 1, meta)}

        {{:., meta, [mod, fun]}, _, args} = node, acc when is_atom(fun) and is_list(args) ->
          {node, record(acc, expand(mod, aliases), fun, length(args), meta)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp record(acc, module, fun, arity, meta) do
    if forbidden?(module, fun),
      do: [{Module.concat(module), fun, arity, meta[:line]} | acc],
      else: acc
  end

  defp forbidden?([:Ash, :Resource, :Info], _fun), do: true
  defp forbidden?([:Ash, :DataLayer | _], _fun), do: true
  defp forbidden?([:Application], fun), do: fun in @app_env_funs
  defp forbidden?(_module, _fun), do: false

  # Short name => full alias segments, for every `alias` in the file.
  defp collect_aliases(ast) do
    {_, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [{:__aliases__, _, segments}]} = node, acc ->
          {node, Map.put(acc, List.last(segments), segments)}

        {:alias, _, [{:__aliases__, _, segments}, opts]} = node, acc when is_list(opts) ->
          case Keyword.get(opts, :as) do
            {:__aliases__, _, [as]} -> {node, Map.put(acc, as, segments)}
            nil -> {node, Map.put(acc, List.last(segments), segments)}
          end

        {:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]} = node, acc ->
          {node,
           Enum.reduce(children, acc, fn {:__aliases__, _, child}, acc ->
             Map.put(acc, List.last(child), base ++ child)
           end)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp expand({:__aliases__, _, [head | rest]}, aliases),
    do: Map.get(aliases, head, [head]) ++ rest

  defp expand(_mod, _aliases), do: nil

  defp failure(title, violations), do: Enum.join([title <> ":" | violations], "\n  ")
end
