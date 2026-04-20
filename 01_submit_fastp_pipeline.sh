#!/usr/bin/env bash

# Submit sample-level FASTQ merge + fastp jobs as a SLURM array.
# Note: intentionally not using `set -euo pipefail` per user requirement.
#
# Design goals:
# 1) Parallelism at sample_id level (not FASTQ shard level).
# 2) Generate a unique sample list file for deterministic array indexing.
# 3) Pass all runtime configs to worker script via sbatch exports.

usage() {
  cat <<'USAGE'
Usage:
  bash 01_submit_fastp_pipeline.sh \
    -i /abs/path/samples.tsv \
    -o /abs/path/output \
    -p cpu2 \
    -t 4 \
    -m 32G \
    --max-parallel 3 \
    [--force]

Required:
  -i, --input           Input samples TSV (header required: sample_id<TAB>input_R1<TAB>input_R2)
  -o, --outdir          Output root directory

Optional:
  -p, --partition       SLURM partition (default: cpu)
  -t, --threads         fastp threads per sample (default: 4)
  -m, --mem             Memory per array task, passed to sbatch --mem (default: 16G)
      --max-parallel    Max concurrent samples in array (default: 2)
      --force           Force overwrite existing outputs in worker
      --job-name        SLURM job name (default: fastp_pipeline)
      --worker-script   Path to worker script (default: 02_run_fastp_pipeline_array.sh in same dir)
  -h, --help            Show this help message

Directory layout:
  OUTDIR/
    merged/
    fastp/
    reports_fastp/<sample_id>/

  SUBMIT_CWD/
    logs/
    meta/
USAGE
}

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
  fi
}

# Resolve absolute path for an existing file.
abs_file() {
  local p="$1"
  if [[ ! -f "$p" ]]; then
    echo "[ERROR] File does not exist: $p" >&2
    exit 1
  fi
  p="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  echo "$p"
}

# Resolve absolute path for directory (may not exist yet).
abs_dir() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  else
    local parent
    parent="$(dirname "$p")"
    local base
    base="$(basename "$p")"
    if [[ ! -d "$parent" ]]; then
      echo "[ERROR] Parent directory does not exist: $parent" >&2
      exit 1
    fi
    echo "$(cd "$parent" && pwd -P)/$base"
  fi
}

INPUT_TSV=""
OUTDIR=""
PARTITION="cpu"
THREADS="4"
MEM="16G"
MAX_PARALLEL="2"
FORCE=0
JOB_NAME="fastp_pipeline"
WORKER_SCRIPT=""
SUBMIT_CWD="$(pwd -P)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)
      INPUT_TSV="${2:-}"
      shift 2
      ;;
    -o|--outdir)
      OUTDIR="${2:-}"
      shift 2
      ;;
    -p|--partition)
      PARTITION="${2:-}"
      shift 2
      ;;
    -t|--threads)
      THREADS="${2:-}"
      shift 2
      ;;
    -m|--mem)
      MEM="${2:-}"
      shift 2
      ;;
    --max-parallel)
      MAX_PARALLEL="${2:-}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --job-name)
      JOB_NAME="${2:-}"
      shift 2
      ;;
    --worker-script)
      WORKER_SCRIPT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_TSV" || -z "$OUTDIR" ]]; then
  echo "[ERROR] --input and --outdir are required." >&2
  usage >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR] --threads must be a positive integer: $THREADS" >&2
  exit 1
fi

if ! [[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR] --max-parallel must be a positive integer: $MAX_PARALLEL" >&2
  exit 1
fi

if [[ -z "$WORKER_SCRIPT" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  WORKER_SCRIPT="$SCRIPT_DIR/02_run_fastp_pipeline_array.sh"
fi

INPUT_TSV="$(abs_file "$INPUT_TSV")"
OUTDIR="$(abs_dir "$OUTDIR")"
WORKER_SCRIPT="$(abs_file "$WORKER_SCRIPT")"

# Validate TSV header strictly (skip only first line later).
header="$(head -n 1 "$INPUT_TSV" || true)"
if [[ "$header" != $'sample_id\tinput_R1\tinput_R2' ]]; then
  echo "[ERROR] Invalid TSV header in $INPUT_TSV" >&2
  echo "        Expected: sample_id<TAB>input_R1<TAB>input_R2" >&2
  echo "        Got:      $header" >&2
  exit 1
fi

# Create output directories only when missing.
ensure_dir "$OUTDIR/merged"
ensure_dir "$OUTDIR/fastp"
ensure_dir "$OUTDIR/reports_fastp"
ensure_dir "$SUBMIT_CWD/logs"
ensure_dir "$SUBMIT_CWD/meta"

# Build unique sample list in stable first-seen order, skipping TSV header.
sample_list="$SUBMIT_CWD/meta/sample_ids.txt"
awk -F '\t' '
  NR==1 { next }
  NF==0 { next }
  {
    sid=$1
    if (sid=="") next
    if (!(sid in seen)) {
      seen[sid]=1
      print sid
    }
  }
' "$INPUT_TSV" > "$sample_list"

sample_count="$(wc -l < "$sample_list" | tr -d '[:space:]')"
if [[ "$sample_count" == "0" ]]; then
  echo "[ERROR] No sample_id found in: $INPUT_TSV" >&2
  exit 1
fi

array_spec="0-$((sample_count - 1))%${MAX_PARALLEL}"
force_flag="0"
if [[ "$FORCE" -eq 1 ]]; then
  force_flag="1"
fi

echo "[INFO] Input TSV        : $INPUT_TSV"
echo "[INFO] Sample list      : $sample_list"
echo "[INFO] Sample count     : $sample_count"
echo "[INFO] Worker script    : $WORKER_SCRIPT"
echo "[INFO] Output directory : $OUTDIR"
echo "[INFO] Submit cwd       : $SUBMIT_CWD"
echo "[INFO] Array spec       : $array_spec"
echo "[INFO] Threads/sample   : $THREADS"
echo "[INFO] Memory/task      : $MEM"

sbatch \
  --job-name "$JOB_NAME" \
  --partition "$PARTITION" \
  --cpus-per-task "$THREADS" \
  --mem "$MEM" \
  --array "$array_spec" \
  --output "$SUBMIT_CWD/logs/slurm_%x_%A_%a.out" \
  --error "$SUBMIT_CWD/logs/slurm_%x_%A_%a.err" \
  --export "ALL,INPUT_TSV=$INPUT_TSV,SAMPLE_LIST=$sample_list,OUTDIR=$OUTDIR,THREADS=$THREADS,FORCE=$force_flag" \
  "$WORKER_SCRIPT"
