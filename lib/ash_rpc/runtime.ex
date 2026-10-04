# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshRpc.Runtime do
  @moduledoc """
  Everything a request needs from its profile and manifest, resolved once
  and threaded through the pipeline instead of read from globals.
  """

  @type t :: %__MODULE__{
          profile: module() | nil,
          manifest: Ash.Info.Manifest.t(),
          mapping_source: module(),
          input_formatter: AshRpc.MappingSource.formatter(),
          output_formatter: AshRpc.MappingSource.formatter(),
          resource_lookup: map(),
          type_lookup: map(),
          action_lookup: map(),
          entrypoints: %{String.t() => AshRpc.Entrypoint.t()}
        }

  @enforce_keys [:manifest, :mapping_source, :input_formatter, :output_formatter]
  defstruct [
    :profile,
    :manifest,
    :mapping_source,
    :input_formatter,
    :output_formatter,
    resource_lookup: %{},
    type_lookup: %{},
    action_lookup: %{},
    entrypoints: %{}
  ]

  @spec new(module(), keyword()) :: t()
  def new(profile, opts \\ []) when is_atom(profile) do
    manifest = Keyword.get_lazy(opts, :manifest, &profile.manifest/0)

    if is_nil(AshRpc.Manifest.ash_rpc(manifest)) do
      raise ArgumentError,
            "the manifest used by #{inspect(profile)} has no custom.ash_rpc decoration; " <>
              "decorate it with AshRpc.Manifest.Decorator.decorate/3 when building it"
    end

    from_manifest(manifest, profile)
  end

  @spec from_manifest(Ash.Info.Manifest.t(), module() | nil) :: t()
  def from_manifest(%Ash.Info.Manifest{} = manifest, profile \\ nil) do
    rpc = AshRpc.Manifest.ash_rpc!(manifest)

    %__MODULE__{
      profile: profile,
      manifest: manifest,
      mapping_source: rpc.mapping_source,
      input_formatter: rpc.input_formatter,
      output_formatter: rpc.output_formatter,
      resource_lookup: rpc.lookups.resource,
      type_lookup: rpc.lookups.type,
      action_lookup: rpc.lookups.action,
      entrypoints: rpc.entrypoints
    }
  end
end
