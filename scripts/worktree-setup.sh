#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 ash_rpc contributors <https://github.com/ash-project/ash_rpc/graphs/contributors>
#
# SPDX-License-Identifier: MIT

# Prepare a git worktree of ash_rpc for development.
#
#   scripts/worktree-setup.sh [worktree-path]
#
# Opt-in and tool-agnostic: nothing in the repo runs it. Call it by hand, or
# from your own local Orca, wt or other worktree tooling configuration. The
# worktree defaults to the current directory. Safe to re-run.
#
# `mise trust` lets the checkout's mise config run code, so only run this on
# reviewed code, never on an external PR branch.

set -euo pipefail

worktree=$(cd "${1:-.}" && git rev-parse --show-toplevel)
cd "$worktree"
echo "==> Setting up worktree $worktree"

# Trust the checkout's .tool-versions and install any runtimes this machine
# does not have yet.
mise trust --quiet .
mise install

echo "==> Done"
