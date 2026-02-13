#!/bin/bash
# ---------------------------------------------------------------------------
# Full benchmark sweep: single-node vs multi-node comparison
#
# Runs every (nprocs, mesh-level) combination on all requested node counts.
# Each call to benchmark.sh submits one sbatch job per node count.
#
# Usage:
#   ./sweep.sh <container.sif> --nodes 1,2 [benchmark.sh flags ...]
#
# Example:
#   ./sweep.sh bench.sif --nodes 1,2 --account vsk46 --partition dc-cpu
# ---------------------------------------------------------------------------
set -euo pipefail

SIF="${1:?Usage: $0 <container.sif> --nodes 1,2 [benchmark.sh flags ...]}"
shift
PASSTHROUGH=("$@")

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

for NPROCS in 2 4 8 16; do
    for MESH_LEVEL in 1 2 3 4; do
        echo "=========================================="
        echo "nprocs=${NPROCS}, mesh-level=${MESH_LEVEL}"
        echo "=========================================="
        "${BENCH_DIR}/benchmark.sh" \
            --container "$SIF" \
            --nprocs "$NPROCS" \
            --mesh-level "$MESH_LEVEL" \
            --output-dir "${RESULTS_DIR}/np${NPROCS}_ml${MESH_LEVEL}" \
            "${PASSTHROUGH[@]}"
        echo ""
    done
done

# Combine all per-run CSVs
echo "nodes,nprocs,mesh_level,cells,wall_time_seconds,exit_code" \
    > "${RESULTS_DIR}/combined_results.csv"
for f in "${RESULTS_DIR}"/np*_ml*/benchmark_results.csv; do
    tail -n +2 "$f" >> "${RESULTS_DIR}/combined_results.csv"
done

echo "=========================================="
echo "Combined results: ${RESULTS_DIR}/combined_results.csv"
echo "=========================================="
cat "${RESULTS_DIR}/combined_results.csv"
