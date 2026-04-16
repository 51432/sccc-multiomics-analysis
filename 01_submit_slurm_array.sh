#!/usr/bin/env bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config/00_config.sh"
source "${ROOT}/lib/validate_samples_tsv.sh"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") --samples samples.tsv --mode wes|wgs [--max-parallel 8] [--check-pairs 1|0]

EOF
}

SAMPLES="${SAMPLES_TSV}"
MODE_ARG="${MODE}"
MAXP="${MAX_PARALLEL}"
CHECK_PAIRS="${ENABLE_CHECK_PAIRS}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --samples) SAMPLES="$2"; shift 2;;
    --mode) MODE_ARG="$2"; shift 2;;
    --max-parallel) MAXP="$2"; shift 2;;
    --check-pairs) CHECK_PAIRS="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "[ERROR] unknown arg: $1" >&2; usage; exit 1;;
  esac
done

export MODE="${MODE_ARG}"
export SAMPLES_TSV="${SAMPLES}"
export MAX_PARALLEL="${MAXP}"
export ENABLE_CHECK_PAIRS="${CHECK_PAIRS}"

# 重新加载使 mode 生效
source "${ROOT}/config/00_config.sh"

num_samples="$(validate_samples_tsv "${SAMPLES_TSV}")"
array_end=$((num_samples - 1))

log "samples=${num_samples}, array=0-${array_end}%${MAX_PARALLEL}, mode=${MODE}, check_pairs=${ENABLE_CHECK_PAIRS}"

sbatch \
  --export=ALL,SAMPLES_TSV="${SAMPLES_TSV}",MODE="${MODE}",ENABLE_CHECK_PAIRS="${ENABLE_CHECK_PAIRS}" \
  --array="0-${array_end}%${MAX_PARALLEL}" \
  "${ROOT}/run_sample_array.sbatch"
