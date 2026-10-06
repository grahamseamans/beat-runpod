#!/bin/sh
# Fail unless the BEAT bundle for backend $1 (cpu | cuda) loads and its coupled precompile workload solved.
# The workload's outcome is serialized into the bundle's package image as CoupledWorker.WORKLOAD[]
# (BEAT Engine 0.3.0+ti2, julia_engine/BeatEngineCoupledWorker.jl).
set -eu
backend="$1"
case "$backend" in
  cpu) bundle=BeatEngineCpuBundle ;;
  cuda) bundle=BeatEngineCudaBundle ;;
  *) echo "beat-workload.sh: unknown backend '$backend'" >&2; exit 2 ;;
esac
project=$(/opt/blab-venv/bin/python -c "from beat_engine import engine_paths; print(engine_paths('$backend').project)")
julia --startup-file=no --project="$project" -e "
using $bundle
status = $bundle.CoupledWorker.WORKLOAD[]
println(\"$bundle coupled workload: \", status)
startswith(status, \"solved\") || exit(1)"
