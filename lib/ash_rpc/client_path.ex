# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.ClientPath do
  @moduledoc false
  # Names an internal path (atoms, list indexes, client strings) for the
  # client by walking the decorated manifest from a root:
  #
  #   * `{:root, resource, action}`: the first atom is an action input when the
  #     action declares it (argument overrides apply), else a resource field or
  #     relationship
  #   * `{:resource, resource}`: a resource field or relationship; the walk
  #     continues in the field's type or the relationship's destination
  #   * `{:type, type}`: a typed container field, a union member, an array item
  #     (`:type_ref` nodes resolve through the type lookup)
  #
  # Atoms take the decorated client name of the node they are on. Integers keep
  # the current node. A string is a name the client sent: it is reported as
  # sent and ends the walk. Once the walk leaves decorated data (a miss, an
  # undecorated node, an unconstrained map), atoms use the output formatter.

  alias Ash.Info.Manifest
  alias Ash.Info.Manifest.Type
  alias AshRpc.{FieldFormatter, Introspection}
  alias AshRpc.Manifest.Custom

  @type context ::
          {:root, Manifest.Resource.t() | nil, Manifest.Action.t() | nil}
          | {:resource, Manifest.Resource.t()}
          | {:type, Type.t()}
          | :none

  @doc false
  @spec root(AshRpc.Runtime.t(), module() | nil, atom() | nil) :: context()
  def root(rt, resource, action) do
    resource_struct = resource && Map.get(rt.resource_lookup, resource)
    action_struct = resource && action && Map.get(rt.action_lookup, {resource, action})
    {:root, resource_struct, action_struct}
  end

  @doc false
  # Where field-selection paths start: a generic action's decorated return
  # type, otherwise the entrypoint's resource.
  @spec selection_root(AshRpc.Runtime.t(), module() | nil, Manifest.Action.t() | nil) ::
          context()
  def selection_root(_rt, _resource, %Manifest.Action{type: :action, returns: %Type{} = returns}),
    do: {:type, returns}

  def selection_root(rt, resource, _action), do: resource_context(resource, rt)

  @doc false
  @spec resolve(list(), context(), AshRpc.Runtime.t()) :: {list(), context()}
  def resolve(path, ctx, rt) when is_list(path) do
    {names, leaf} =
      Enum.reduce(path, {[], ctx}, fn
        index, {acc, ctx} when is_integer(index) ->
          {[index | acc], ctx}

        segment, {acc, ctx} when is_atom(segment) ->
          {name, next} = segment(ctx, segment, rt)
          {[name | acc], next}

        other, {acc, _ctx} ->
          {[other | acc], :none}
      end)

    {Enum.reverse(names), leaf}
  end

  @doc false
  @spec name(context(), term(), AshRpc.Runtime.t()) :: term()
  def name(ctx, field, rt) when is_atom(field) and not is_nil(field) do
    {name, _next} = segment(ctx, field, rt)
    name
  end

  def name(_ctx, field, _rt), do: field

  # ── segments ──────────────────────────────────────────────────────

  defp segment({:root, %Manifest.Resource{} = r, %Manifest.Action{} = action}, seg, rt) do
    types = Custom.action_input_field_types(action) || %{}

    if Map.has_key?(types, seg) do
      name = Introspection.format_input_name(r, action.name, seg, rt.output_formatter)
      {name, type_context(Map.get(types, seg))}
    else
      segment({:resource, r}, seg, rt)
    end
  end

  defp segment({:root, %Manifest.Resource{} = r, _action}, seg, rt),
    do: segment({:resource, r}, seg, rt)

  defp segment({:resource, %Manifest.Resource{} = r}, seg, rt) do
    case Map.fetch(Custom.field_names(r), seg) do
      {:ok, name} -> {name, resource_child(r, seg, rt)}
      :error -> formatted(seg, rt)
    end
  end

  defp segment({:type, %Type{} = type}, seg, rt) do
    case decorated_type(type, rt) do
      %Type{kind: :type_ref} ->
        formatted(seg, rt)

      %Type{kind: :array, item_type: item} ->
        segment(type_context(item), seg, rt)

      %Type{} = t ->
        if Type.resource_kind?(t),
          do: segment(resource_context(Type.effective_resource(t), rt), seg, rt),
          else: container_segment(t, seg, rt)
    end
  end

  defp segment(_ctx, seg, rt), do: formatted(seg, rt)

  defp container_segment(%Type{kind: :union} = t, seg, rt) do
    case Map.fetch(Custom.type_member_names(t), seg) do
      {:ok, name} -> {name, t |> Type.find_member(seg) |> member_type() |> type_context()}
      :error -> formatted(seg, rt)
    end
  end

  defp container_segment(%Type{} = t, seg, rt) do
    case Map.fetch(Custom.type_field_names(t), seg) do
      {:ok, name} -> {name, type_context(Type.find_field_type(t, seg))}
      :error -> formatted(seg, rt)
    end
  end

  defp resource_child(%Manifest.Resource{} = r, seg, rt) do
    case {Map.get(r.fields, seg), Map.get(r.relationships, seg)} do
      {%Manifest.Field{type: type}, _} -> type_context(type)
      {nil, %Manifest.Relationship{destination: dest}} -> resource_context(dest, rt)
      _ -> :none
    end
  end

  defp resource_context(module, rt) do
    case module && Map.get(rt.resource_lookup, module) do
      %Manifest.Resource{} = r -> {:resource, r}
      _ -> :none
    end
  end

  defp type_context(%Type{} = type), do: {:type, type}
  defp type_context(_), do: :none

  defp member_type(%{type: %Type{} = type}), do: type
  defp member_type(_), do: nil

  @doc false
  # A node without decoration (a named reference, or a copy taken before
  # decoration) resolves through the type lookup entry for its module.
  @spec decorated_type(Type.t(), AshRpc.Runtime.t()) :: Type.t()
  def decorated_type(%Type{custom: %{ash_rpc: _}} = type, _rt), do: type

  def decorated_type(%Type{kind: :type_ref, module: m} = type, rt),
    do: Manifest.get_type(rt.type_lookup, m) || type

  def decorated_type(%Type{} = type, rt) do
    if Type.resource_kind?(type) or type.kind == :array do
      type
    else
      case Type.effective_module(type) do
        nil -> type
        module -> Manifest.get_type(rt.type_lookup, module) || type
      end
    end
  end

  defp formatted(seg, rt), do: {FieldFormatter.format_field_name(seg, rt.output_formatter), :none}
end
