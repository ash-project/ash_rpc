# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Manifest do
  @moduledoc """
  Readers for the `custom.ash_rpc` decoration on an `%Ash.Info.Manifest{}`.
  """

  alias Ash.Info.Manifest

  @spec ash_rpc(Manifest.t() | term()) :: map() | nil
  def ash_rpc(%Manifest{custom: %{ash_rpc: data}}), do: data
  def ash_rpc(_), do: nil

  @spec ash_rpc!(Manifest.t()) :: map()
  def ash_rpc!(manifest) do
    ash_rpc(manifest) ||
      raise ArgumentError,
            "manifest has no custom.ash_rpc decoration; build it with AshRpc.Manifest.Decorator.decorate/3"
  end

  @doc """
  Returns the manifest owned by `module`: Spark DSL modules persist it under
  `:manifest` (e.g. an extension's manifest DSL module); any other module must
  export `manifest/0`.
  """
  @spec fetch!(module()) :: Manifest.t()
  def fetch!(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :spark_dsl_config, 0) do
      Spark.Dsl.Extension.get_persisted(module, :manifest)
    else
      module.manifest()
    end
  end

  def mapping_source(m), do: ash_rpc!(m).mapping_source
  def input_formatter(m), do: ash_rpc!(m).input_formatter
  def output_formatter(m), do: ash_rpc!(m).output_formatter

  @spec entrypoint_lookup(Manifest.t()) :: %{String.t() => AshRpc.Entrypoint.t()}
  def entrypoint_lookup(m), do: ash_rpc!(m).entrypoints

  def resource_lookup(m), do: ash_rpc!(m).lookups.resource
  def type_lookup(m), do: ash_rpc!(m).lookups.type
  def action_lookup(m), do: ash_rpc!(m).lookups.action

  @doc """
  (Re)builds `custom.ash_rpc.lookups` from the manifest as it is now. Call it
  after the last decorator that touches resources, types or actions.
  """
  @spec put_lookups(Manifest.t()) :: Manifest.t()
  def put_lookups(%Manifest{} = manifest) do
    lookups = %{
      resource: build_resource_lookup(manifest),
      type: Manifest.type_lookup(manifest),
      action: Manifest.action_lookup(manifest)
    }

    rpc = manifest |> ash_rpc!() |> Map.put(:lookups, lookups)
    %Manifest{manifest | custom: Map.put(manifest.custom, :ash_rpc, rpc)}
  end

  @doc """
  Resource lookup including embedded resources, which Ash keeps in
  `manifest.types` as `kind: :embedded_resource` entries.
  """
  @spec build_resource_lookup(Manifest.t()) :: %{module() => Manifest.Resource.t()}
  def build_resource_lookup(%Manifest{} = manifest) do
    embedded =
      for %Manifest.Type{
            kind: :embedded_resource,
            module: mod,
            resource: %Manifest.Resource{} = r
          } <-
            manifest.types,
          into: %{},
          do: {mod, r}

    Map.merge(embedded, Manifest.resource_lookup(manifest))
  end

  @doc """
  Re-runs `AshRpc.Manifest.Decorator` with the stored mapping source,
  overriding `:input_formatter` / `:output_formatter`. For tests.
  """
  @spec redecorate(Manifest.t(), keyword()) :: Manifest.t()
  def redecorate(%Manifest{} = manifest, opts) do
    source = mapping_source(manifest)

    unless Code.ensure_loaded?(source) do
      raise ArgumentError,
            "mapping source #{inspect(source)} stored on the manifest is not loaded"
    end

    AshRpc.Manifest.Decorator.decorate(
      manifest,
      source,
      Keyword.take(opts, [:input_formatter, :output_formatter])
    )
  end
end
