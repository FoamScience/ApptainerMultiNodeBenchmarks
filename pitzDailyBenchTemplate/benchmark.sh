#!/usr/bin/env bash
# pitzDaily single-node vs multi-node benchmark
#
# Prepares a case once (blockMesh + decomposePar on login node), then submits
# the solver via sbatch for each requested node count. Same nprocs and mesh
# across all runs so results are directly comparable.
#
# Usage:
#   benchmark.sh --container SIF --nprocs N --mesh-level L --nodes 1,2,4 [OPTIONS]
set -euo pipefail
set -xe

CONTAINER=""
NPROCS=""
MESH_LEVEL=""
NODES_LIST=""
END_TIME=""
OUTPUT_DIR=""
PARTITION=""
ACCOUNT=""
TIME="02:00:00"
SBATCH_EXTRA=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MESH_PARAMS_1="20 25 15 15"
MESH_PARAMS_2="40 50 30 30"
MESH_PARAMS_3="80 100 60 60"
MESH_PARAMS_4="160 200 120 120"

usage() {
    cat <<EOF
Usage: $0 --container SIF --nprocs N --mesh-level L --nodes 1,2[,4,...] [OPTIONS]

Runs the same case (nprocs x mesh) on each node count for direct comparison.

Required:
  --container SIF          Path to the Apptainer .sif container
  --nprocs N               Total MPI processes (constant across all runs)
  --mesh-level L           Mesh refinement level 1-4 (constant across all runs)
  --nodes 1,2[,4,...]      Comma-separated node counts to compare

Slurm options:
  --partition P            Slurm partition (e.g. dc-cpu)
  --account A              Slurm account/project
  --time HH:MM:SS          Wall-time limit (default: 02:00:00)
  --sbatch-args STR        Any extra sbatch flags (e.g. '--mail-type=ALL')

Other:
  --end-time T             Simulation end time (default: 0.1)
  --output-dir DIR         Working directory (default: /tmp/pitzDailyBench.\$\$)

Example:
  $0 --container bench.sif --nprocs 16 --mesh-level 3 --nodes 1,2 \\
     --account vsk46 --partition dc-cpu
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container)    CONTAINER="$2";    shift 2 ;;
        --nprocs)       NPROCS="$2";       shift 2 ;;
        --mesh-level)   MESH_LEVEL="$2";   shift 2 ;;
        --nodes)        NODES_LIST="$2";   shift 2 ;;
        --partition)    PARTITION="$2";     shift 2 ;;
        --account)      ACCOUNT="$2";      shift 2 ;;
        --time)         TIME="$2";         shift 2 ;;
        --end-time)     END_TIME="$2";     shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";   shift 2 ;;
        --sbatch-args)  SBATCH_EXTRA="$2"; shift 2 ;;
        -h|--help)      usage ;;
        *)              echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$CONTAINER" || -z "$NPROCS" || -z "$MESH_LEVEL" || -z "$NODES_LIST" ]]; then
    echo "Error: --container, --nprocs, --mesh-level, and --nodes are all required"
    usage
fi

if [[ ! -f "$CONTAINER" ]]; then
    echo "Error: container not found: $CONTAINER"
    exit 1
fi
CONTAINER="$(cd "$(dirname "$CONTAINER")" && pwd)/$(basename "$CONTAINER")"

if [[ "$MESH_LEVEL" -lt 1 || "$MESH_LEVEL" -gt 4 ]]; then
    echo "Error: --mesh-level must be between 1 and 4"
    exit 1
fi

# Parse comma-separated node counts
IFS=',' read -ra NODES_ARRAY <<< "$NODES_LIST"

# ---------------------------------------------------------------------------
# Preflight: verify required binaries in the container
# ---------------------------------------------------------------------------
REQUIRED_BINS=(blockMesh decomposePar pisoFoam)
echo "Checking container for required binaries..."
for bin in "${REQUIRED_BINS[@]}"; do
    if ! apptainer exec "$CONTAINER" bash -c "command -v $bin" &>/dev/null; then
        echo "Error: '$bin' not found in container $CONTAINER"
        exit 1
    fi
done
echo "All required binaries found."

# ---------------------------------------------------------------------------
# Setup working directory (on host / login node)
# ---------------------------------------------------------------------------
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/tmp/pitzDailyBench.$$"
fi
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
cp -r "$SCRIPT_DIR"/0 "$SCRIPT_DIR"/constant "$SCRIPT_DIR"/system "$OUTPUT_DIR"/

# ---------------------------------------------------------------------------
# Substitute template placeholders (on host)
# ---------------------------------------------------------------------------
MESH_VAR="MESH_PARAMS_${MESH_LEVEL}"
read -r XCELLS_IN XCELLS_OUT YCELLS_UP YCELLS_LOW <<< "${!MESH_VAR}"

sed -i "s/__XCELLS_IN__/${XCELLS_IN}/g"   "$OUTPUT_DIR/system/blockMeshDict"
sed -i "s/__XCELLS_OUT__/${XCELLS_OUT}/g"  "$OUTPUT_DIR/system/blockMeshDict"
sed -i "s/__YCELLS_UP__/${YCELLS_UP}/g"    "$OUTPUT_DIR/system/blockMeshDict"
sed -i "s/__YCELLS_LOW__/${YCELLS_LOW}/g"  "$OUTPUT_DIR/system/blockMeshDict"
sed -i "s/__NPROCS__/${NPROCS}/g"          "$OUTPUT_DIR/system/decomposeParDict"

if [[ -n "$END_TIME" ]]; then
    sed -i "s/^endTime.*/endTime         ${END_TIME};/" "$OUTPUT_DIR/system/controlDict"
fi

# ---------------------------------------------------------------------------
# Case preparation (serial, on login node through the container)
# ---------------------------------------------------------------------------
foam_exec() {
	cd "${OUTPUT_DIR}"
    apptainer exec "$CONTAINER" "$@"
}

echo ">>> blockMesh"
foam_exec blockMesh > "$OUTPUT_DIR/blockMesh.log" 2>&1
CELL_COUNT=$(grep -oP 'nCells:\s*\K[0-9]+' "$OUTPUT_DIR/blockMesh.log" || echo "0")
if [[ -z "$CELL_COUNT" || "$CELL_COUNT" == "0" ]]; then
    CELL_COUNT=$(grep -oP 'cells:\s*\K[0-9]+' "$OUTPUT_DIR/blockMesh.log" || echo "0")
fi
echo "    cells: ${CELL_COUNT}"

echo ">>> decomposePar"
foam_exec decomposePar > "$OUTPUT_DIR/decomposePar.log" 2>&1

# ---------------------------------------------------------------------------
# Submit solver for each node count
# ---------------------------------------------------------------------------
CSV_FILE="${OUTPUT_DIR}/benchmark_results.csv"
echo "nodes,nprocs,mesh_level,cells,wall_time_seconds,exit_code" > "$CSV_FILE"

for NODE_COUNT in "${NODES_ARRAY[@]}"; do
    TASKS_PER_NODE=$(( (NPROCS + NODE_COUNT - 1) / NODE_COUNT ))
    RUN_DIR="${OUTPUT_DIR}/nodes_${NODE_COUNT}"
    mkdir -p "$RUN_DIR"

    # Generate sbatch script for this node count
    {
        echo "#!/bin/bash -x"
        [[ -n "$ACCOUNT" ]]  && echo "#SBATCH --account=${ACCOUNT}"
        echo "#SBATCH --job-name=pisoFoam-np${NPROCS}-ml${MESH_LEVEL}-n${NODE_COUNT}"
        echo "#SBATCH --nodes=${NODE_COUNT}"
        echo "#SBATCH --ntasks=${NPROCS}"
        echo "#SBATCH --ntasks-per-node=${TASKS_PER_NODE}"
        echo "#SBATCH --cpus-per-task=1"
        echo "#SBATCH --output=${RUN_DIR}/pisoFoam.%j.log"
        echo "#SBATCH --error=${RUN_DIR}/pisoFoam.%j.err"
        echo "#SBATCH --time=${TIME}"
        [[ -n "$PARTITION" ]] && echo "#SBATCH --partition=${PARTITION}"
        cat <<SBATCH_EOF

module load Stages/2024 GCC/12.3.0
module load OpenMPI/4.1.5
START_TIME=\$(date +%s.%N)
cd "${OUTPUT_DIR}"
srun apptainer exec ${CONTAINER} pisoFoam -parallel
EXIT_CODE=\$?
END_TIME=\$(date +%s.%N)
WALL_TIME=\$(echo "\$END_TIME - \$START_TIME" | bc)

echo "${NODE_COUNT},${NPROCS},${MESH_LEVEL},${CELL_COUNT},\${WALL_TIME},\${EXIT_CODE}" >> "${CSV_FILE}"
SBATCH_EOF
    } > "${RUN_DIR}/solver.sbatch"

    echo ">>> Submitting solver on ${NODE_COUNT} node(s) (nprocs=${NPROCS}, mesh_level=${MESH_LEVEL}, cells=${CELL_COUNT})"
    # shellcheck disable=SC2086
    JOBID=$(sbatch --parsable --wait ${SBATCH_EXTRA} "${RUN_DIR}/solver.sbatch")
    echo "    Slurm job ${JOBID} completed"
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo ""
echo "=== Benchmark Results (nprocs=${NPROCS}, mesh_level=${MESH_LEVEL}, cells=${CELL_COUNT}) ==="
cat "$CSV_FILE"
echo ""
echo "Work dir: ${OUTPUT_DIR}"
