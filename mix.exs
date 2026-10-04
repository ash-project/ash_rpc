defmodule AshRpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :ash_rpc,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      elixirc_paths: elixirc_paths(Mix.env()),
      usage_rules: usage_rules(),
      deps: deps()
    ]
  end

  # Read by `mix usage_rules.sync`: link the usage rules relevant to developing
  # this library into AGENTS.md as `@deps/...` references. Same as
  # ash_typescript minus spark, igniter and ex_check: ash_rpc defines no Spark
  # DSLs or Igniter tasks, and usage_rules only links direct dependencies.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {:ash, link: :at, except: [:migrations, :generating_code]},
        {:usage_rules, link: :at, except: [:otp]}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.27"},
      {:jason, "~> 1.0"},
      {:plug, "~> 1.14", optional: true},
      {:phoenix, "~> 1.7", optional: true},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.2", only: [:dev], runtime: false}
    ]
  end
end
