#!/usr/bin/env bash
# mlx-server.sh — stub wrapper.
#
# The canonical mlx_lm.server launcher now lives in the agents repo:
#   ~/Code/agents/local-llm-offload/mlx-server.sh
# reached through the stable symlink ~/.local/bin/mlx-server.sh. This stub keeps
# `./mlx-server.sh` working from this repo (llm-switch.sh's "start it first" UX)
# while there is a single source of truth. Pass-through of args/aliases is verbatim.
exec ~/.local/bin/mlx-server.sh "$@"
