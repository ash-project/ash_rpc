# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

[
  ## all available options with default values (see `mix check` docs for description)
  # parallel: true,
  # skipped: true,

  ## list of tools (see `mix check` docs for defaults)
  tools: [
    ## curated tools may be disabled (e.g. the check for compilation warnings)
    # {:compiler, false},

    ## ...or adjusted (e.g. use one-line formatter for more compact credo output)
    # {:credo, "mix credo --format oneline"},

    {:compiler, "mix compile --warnings-as-errors"},
    {:format, "mix format --check-formatted"},
    # The `charset-normalizer` extra is required: without it reuse falls back to
    # `python-magic`, which needs libmagic installed system-wide and otherwise
    # fails to import with `NoEncodingModuleError`.
    {:reuse,
     command: ["pipx", "run", "--spec", "reuse[charset-normalizer]", "reuse", "lint", "-q"]},
    {:credo, "mix credo --strict"},
    {:sobelow, "mix sobelow --config"}

    ## custom new tools may be added (mix tasks or arbitrary commands)
    # {:my_mix_task, command: "mix release", env: %{"MIX_ENV" => "prod"}},
    # {:my_arbitrary_tool, command: "npm test", cd: "assets"},
    # {:my_arbitrary_script, command: ["my_script", "argument with spaces"], cd: "scripts"}
  ]
]
