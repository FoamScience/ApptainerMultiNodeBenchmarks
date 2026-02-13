# Multi-Node OpenFOAM Benchmark

Compares containerized pisoFoam solver wall-time across node counts on a Slurm cluster. The same case (nprocs, cell count) runs on each node configuration so results are directly comparable.

## Running a benchmark

```bash
# Optional; build the containers (or use your own later)
# by default, this pulls from ghcr.io - change it in config.yaml
uvx --with=graphviz hpctainers --config config.yaml

# Aim for ~50k-80k cells per proc here for a fair test
./pitzDailyBenchTemplate/benchmark.sh \
    --container containers/basic/openfoam-ib.sif \
    --nprocs 16 --mesh-level 3 --nodes 1,2 \
    --account myproject --partition dc-cpu
```

This prepares the pitzDaily case once on the login node (blockMesh + decomposePar), then submits one `sbatch` job per node count.

Required:
- `--container SIF` -- path to the `.sif` container
- `--nprocs N` -- total MPI processes (constant across all runs)
- `--mesh-level L` -- mesh refinement 1--4 (Lvl1 -> ~10k cells)
- `--nodes 1,2,...` -- comma-separated node counts to compare

Optional:
- `--partition P` -- Slurm partition
- `--account A` -- Slurm account/project
- `--time HH:MM:SS` -- wall-time limit (default: `02:00:00`)
- `--end-time T` -- simulation end time (default: `0.1`)
- `--output-dir DIR` -- working directory (default: `/tmp/pitzDailyBench.$$`)
- `--sbatch-args STR` -- extra sbatch flags

## Full sweep

Loops over all (nprocs, mesh-level) combinations:

```bash
./pitzDailyBenchTemplate/sweep-benchmark.sh containers/basic/openfoam-ib.sif \
    --nodes 1,2 --account myproject --partition dc-cpu
```

## Results

Single-run results go to `<output-dir>/benchmark_results.csv`. Sweep results go to `results-<timestamp>/combined_results.csv`. Format:

```csv
nodes,nprocs,mesh_level,cells,wall_time_seconds,exit_code
1,16,3,144000,45.12,0
2,16,3,144000,28.67,0
```

- **nodes**: number of Slurm nodes used
- **nprocs**: total MPI processes (same for every row in a single benchmark run)
- **mesh_level**: refinement level 1--4
- **cells**: actual cell count reported by blockMesh
- **wall_time_seconds**: solver-only wall-clock time (excludes meshing and decomposition)
- **exit_code**: solver exit code (`0` = success)

For a given nprocs and mesh, flat-ish `wall_time_seconds` on more nodes indicates good multi-node scaling. If wall time increases, communication overhead dominates at that problem size.

Per-run solver logs are in `<output-dir>/nodes_<N>/pisoFoam.*.log`.
