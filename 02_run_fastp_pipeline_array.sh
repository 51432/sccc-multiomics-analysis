#!/usr/bin/env bash
#SBATCH --ntasks=1
set -euo pipefail

# Worker for one sample (selected by SLURM_ARRAY_TASK_ID):
# 1) Parse all rows for this sample_id from INPUT_TSV.
# 2) Validate paired shard counts and file existence.
# 3) Merge R1 shards and R2 shards separately by cat-ing .fastq.gz chunks.
# 4) Run fastp on merged files.
#
# Required env variables (exported by submit script):
#   INPUT_TSV, SAMPLE_LIST, OUTDIR, THREADS, FORCE

usage() {
  cat <<'USAGE'
Usage (inside SLURM array):
  sbatch ... --export "ALL,INPUT_TSV=/abs/samples.tsv,SAMPLE_LIST=/abs/sample_ids.txt,OUTDIR=/abs/out,THREADS=4,FORCE=0" 02_run_fastp_pipeline_array.sh

Required environment variables:
  INPUT_TSV    Path to input samples TSV.
  SAMPLE_LIST  Path to unique sample_id list.
  OUTDIR       Output root directory.
  THREADS      fastp thread count.
  FORCE        0 or 1. If 1, remove old outputs and rebuild.
USAGE
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "[ERROR] Missing required environment variable: $name" >&2
    usage >&2
    exit 1
  fi
}

require_env "INPUT_TSV"
require_env "SAMPLE_LIST"
require_env "OUTDIR"
require_env "THREADS"
require_env "FORCE"

if [[ -z "${SLURM_ARRAY_TASK_ID:-}" ]]; then
  echo "[ERROR] SLURM_ARRAY_TASK_ID is not set. This script must run as a job array task." >&2
  exit 1
fi

if ! command -v fastp >/dev/null 2>&1; then
  echo "[ERROR] fastp not found in PATH." >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR] THREADS must be a positive integer. Got: $THREADS" >&2
  exit 1
fi

if ! [[ "$FORCE" =~ ^[01]$ ]]; then
  echo "[ERROR] FORCE must be 0 or 1. Got: $FORCE" >&2
  exit 1
fi

if [[ ! -f "$INPUT_TSV" ]]; then
  echo "[ERROR] INPUT_TSV does not exist: $INPUT_TSV" >&2
  exit 1
fi

if [[ ! -f "$SAMPLE_LIST" ]]; then
  echo "[ERROR] SAMPLE_LIST does not exist: $SAMPLE_LIST" >&2
  exit 1
fi

# Create output directories if missing.
mkdir -p "$OUTDIR/merged" "$OUTDIR/fastp" "$OUTDIR/reports_fastp"

task_id="$SLURM_ARRAY_TASK_ID"
sample_id="$(sed -n "$((task_id + 1))p" "$SAMPLE_LIST" || true)"

if [[ -z "$sample_id" ]]; then
  echo "[ERROR] No sample_id found for SLURM_ARRAY_TASK_ID=$task_id in $SAMPLE_LIST" >&2
  exit 1
fi

report_dir="$OUTDIR/reports_fastp/$sample_id"
mkdir -p "$report_dir"

merged_r1="$OUTDIR/merged/${sample_id}.R1.merged.fastq.gz"
merged_r2="$OUTDIR/merged/${sample_id}.R2.merged.fastq.gz"
fastp_r1="$OUTDIR/fastp/${sample_id}.R1.fastp.fastq.gz"
fastp_r2="$OUTDIR/fastp/${sample_id}.R2.fastp.fastq.gz"
report_html="$report_dir/${sample_id}.fastp.html"
report_json="$report_dir/${sample_id}.fastp.json"

log_prefix="[sample=${sample_id} task=${task_id}]"
echo "$log_prefix Start at $(date '+%F %T')"
echo "$log_prefix INPUT_TSV=$INPUT_TSV"
echo "$log_prefix OUTDIR=$OUTDIR"

# Pull all rows for sample_id from TSV (skip header), keep input order.
# Using mapfile to safely preserve spaces in file paths.
mapfile -t r1_files < <(awk -F '\t' -v sid="$sample_id" 'NR>1 && $1==sid {print $2}' "$INPUT_TSV")
mapfile -t r2_files < <(awk -F '\t' -v sid="$sample_id" 'NR>1 && $1==sid {print $3}' "$INPUT_TSV")

r1_count="${#r1_files[@]}"
r2_count="${#r2_files[@]}"

if [[ "$r1_count" -eq 0 && "$r2_count" -eq 0 ]]; then
  echo "[ERROR] $log_prefix No rows found in TSV for sample_id=$sample_id" >&2
  exit 1
fi

if [[ "$r1_count" -ne "$r2_count" ]]; then
  echo "[ERROR] $log_prefix R1/R2 shard count mismatch: R1=$r1_count, R2=$r2_count" >&2
  exit 1
fi

# Verify each input shard exists and is non-empty.
for f in "${r1_files[@]}"; do
  if [[ ! -s "$f" ]]; then
    echo "[ERROR] $log_prefix Missing or empty R1 FASTQ: $f" >&2
    exit 1
  fi
done
for f in "${r2_files[@]}"; do
  if [[ ! -s "$f" ]]; then
    echo "[ERROR] $log_prefix Missing or empty R2 FASTQ: $f" >&2
    exit 1
  fi
done

# Handle force mode: clean prior outputs before rerun.
if [[ "$FORCE" -eq 1 ]]; then
  echo "$log_prefix FORCE=1 -> removing previous outputs"
  rm -f "$merged_r1" "$merged_r2" "$fastp_r1" "$fastp_r2" "$report_html" "$report_json"
fi

# Merge step: skip if both merged files already exist and non-empty (unless FORCE=1 already removed them).
if [[ -s "$merged_r1" && -s "$merged_r2" ]]; then
  echo "$log_prefix Merge skipped (existing merged files are non-empty)."
else
  echo "$log_prefix Merging $r1_count shard pairs"
  tmp_r1="${merged_r1}.tmp.$$"
  tmp_r2="${merged_r2}.tmp.$$"

  # cat .fastq.gz shards directly preserves valid gz stream concatenation.
  cat "${r1_files[@]}" > "$tmp_r1"
  cat "${r2_files[@]}" > "$tmp_r2"

  mv "$tmp_r1" "$merged_r1"
  mv "$tmp_r2" "$merged_r2"
  echo "$log_prefix Merge finished -> $merged_r1, $merged_r2"
fi

# fastp step: skip only when all outputs already exist and non-empty.
if [[ -s "$fastp_r1" && -s "$fastp_r2" && -s "$report_html" && -s "$report_json" ]]; then
  echo "$log_prefix fastp skipped (outputs already exist and are non-empty)."
else
  echo "$log_prefix Running fastp"
  fastp \
    --in1 "$merged_r1" \
    --in2 "$merged_r2" \
    --out1 "$fastp_r1" \
    --out2 "$fastp_r2" \
    --thread "$THREADS" \
    --html "$report_html" \
    --json "$report_json"
  echo "$log_prefix fastp completed"
fi

echo "$log_prefix Done at $(date '+%F %T')"
