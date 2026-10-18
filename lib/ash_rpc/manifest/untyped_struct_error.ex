# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest.UntypedStructError do
  @moduledoc """
  Raised during decoration when a wire entrypoint accepts or returns a struct
  type with no field types (`AshRpc.Introspection.untyped_struct?/1`).

  Fields: `struct_module` (the struct's `instance_of`, `nil` for a bare
  `:struct`), `entrypoint` (`%{name: wire_name, resource: module, action:
  atom}`) and `path` (the root, such as `"returns"` or `"argument :session"`,
  followed by the segments `AshRpc.Introspection.find_untyped_struct/2`
  returned).

  `details/2` is public so extensions can word their own errors with the same
  explanation and alternatives.
  """

  alias Ash.Info.Manifest.Type

  defexception [:message, :struct_module, :entrypoint, :path]

  @type t :: %__MODULE__{
          message: String.t(),
          struct_module: module() | nil,
          entrypoint: %{name: String.t(), resource: module(), action: atom()},
          path: list()
        }

  @doc """
  Builds the error. `type:` (the offending node), `path:` and `entrypoint:`
  (`%{name:, resource:, action:}`) are required; `verb:` is `"accepts"` for
  inputs and `"returns"` otherwise (the default).
  """
  @impl true
  def exception(opts) do
    type = Keyword.fetch!(opts, :type)
    path = Keyword.fetch!(opts, :path)

    %{name: name, resource: resource, action: action} =
      entrypoint = Keyword.fetch!(opts, :entrypoint)

    verb = Keyword.get(opts, :verb, "returns")

    %__MODULE__{
      message:
        "Entrypoint #{inspect(name)} (#{inspect(resource)}, action #{inspect(action)}) " <>
          "#{verb} " <> details(type, path),
      struct_module: type.instance_of,
      entrypoint: entrypoint,
      path: path
    }
  end

  @doc """
  `"an untyped struct, <struct>, at <path>."`, followed by why it is rejected
  and the alternatives. `<struct>` is the `instance_of` module or
  "`:struct` without constraints" (or "`:struct` with no fields" for
  `fields: []`), plus the NewType it was reached through;
  `<path>` joins the segments with ` → ` (`[]` for array items).
  """
  @spec details(Type.t(), list()) :: String.t()
  def details(%Type{} = type, path) do
    """
    an untyped struct, #{describe(type)}, at #{format_path(path)}.

    The manifest has no field types for it, so its fields can't be selected, \
    named or filtered, and every one of them would reach the client. Use one of:
    #{alternatives(type)}\
    """
  end

  defp describe(%Type{instance_of: instance_of, module: module, fields: fields}) do
    base =
      case {instance_of, fields} do
        {nil, []} -> "`:struct` with no fields"
        {nil, _} -> "`:struct` without constraints"
        {struct_module, _} -> inspect(struct_module)
      end

    if module in [nil, Ash.Type.Struct],
      do: base,
      else: "#{base} (through the NewType #{inspect(module)})"
  end

  defp format_path(path) do
    Enum.map_join(path, " → ", fn
      [] -> "[]"
      segment -> to_string(segment)
    end)
  end

  defp alternatives(%Type{instance_of: instance_of}) do
    ash_type =
      if ash_type_module?(instance_of),
        do: [
          "#{inspect(instance_of)} is an Ash type: use it as the type instead of " <>
            "`:struct` with `instance_of`"
        ],
        else: []

    (ash_type ++
       [
         "an Ash.TypedStruct",
         "a NewType over :struct with `fields` constraints",
         "`instance_of` an Ash resource",
         "`:map` with no constraints, converting the struct in the action, " <>
           "for data that is deliberately untyped"
       ])
    |> Enum.map_join("\n", &"  * #{&1}")
  end

  defp ash_type_module?(nil), do: false

  defp ash_type_module?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and Ash.Type.NewType.new_type?(module)
end
