#!/usr/bin/env bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config/00_config.sh"
source "${ROOT}/lib/validate_samples_tsv.sh"

usage() {
  cat <<EOF2
Usage:
  # phase1: fastq/fastp -> bqsr
  $(basename "$0") --pipeline phase1 --samples samples.tsv --mode wes|wgs [--max-parallel 8] [--check-pairs 1|0] [--phase1-end-stage markdup|bqsr]

  # phase2: bqsr tumor-normal -> somatic
  $(basename "$0") --pipeline phase2 --pairs sample_pairs.tsv --mode wes|wgs [--max-parallel 8] \
    [--end-stage mutect2|contamination|orientation|filter|annotation] \
    [--enable-contamination 1|0] [--enable-orientation 1|0] [--enable-annotation 1|0]

EOF2
}

PIPELINE_ARG="${PIPELINE_PHASE}"
SAMPLES="${SAMPLES_TSV}"
PAIRS="${SAMPLE_PAIRS_TSV}"
MODE_ARG="${MODE}"
MAXP="${MAX_PARALLEL}"
CHECK_PAIRS="${ENABLE_CHECK_PAIRS}"
END_STAGE_ARG="${END_STAGE}"
ENABLE_CONTAMINATION_ARG="${ENABLE_CONTAMINATION}"
ENABLE_ORIENTATION_ARG="${ENABLE_ORIENTATION}"
ENABLE_ANNOTATION_ARG="${ENABLE_ANNOTATION}"
PHASE1_END_STAGE_ARG="${PHASE1_END_STAGE}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline) PIPELINE_ARG="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --pairs) PAIRS="$2"; shift 2 ;;
    --mode) MODE_ARG="$2"; shift 2 ;;
    --max-parallel) MAXP="$2"; shift 2 ;;
    --check-pairs) CHECK_PAIRS="$2"; shift 2 ;;
    --end-stage) END_STAGE_ARG="$2"; shift 2 ;;
    --enable-contamination) ENABLE_CONTAMINATION_ARG="$2"; shift 2 ;;
    --enable-orientation) ENABLE_ORIENTATION_ARG="$2"; shift 2 ;;
    --enable-annotation) ENABLE_ANNOTATION_ARG="$2"; shift 2 ;;
    --phase1-end-stage) PHASE1_END_STAGE_ARG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[ERROR] unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

export PIPELINE_PHASE="${PIPELINE_ARG}"
export MODE="${MODE_ARG}"
export MAX_PARALLEL="${MAXP}"
export ENABLE_CHECK_PAIRS="${CHECK_PAIRS}"
export END_STAGE="${END_STAGE_ARG}"
export ENABLE_CONTAMINATION="${ENABLE_CONTAMINATION_ARG}"
export ENABLE_ORIENTATION="${ENABLE_ORIENTATION_ARG}"
export ENABLE_ANNOTATION="${ENABLE_ANNOTATION_ARG}"
export PHASE1_END_STAGE="${PHASE1_END_STAGE_ARG}"

case "${PIPELINE_PHASE}" in
  phase1)
    export SAMPLES_TSV="${SAMPLES}"
    ;;
  phase2)
    export SAMPLE_PAIRS_TSV="${PAIRS}"
    # 为了复用 task 中按行号取值逻辑，把 phase2 的输入也映射到 SAMPLES_TSV
    export SAMPLES_TSV="${SAMPLE_PAIRS_TSV}"
    ;;
  *)
    echo "[ERROR] --pipeline must be phase1|phase2, got=${PIPELINE_PHASE}" >&2
    exit 1
    ;;
esac

# 重新加载使 mode / phase / stage 等配置生效
source "${ROOT}/config/00_config.sh"

if [[ "${PIPELINE_PHASE}" == "phase1" ]]; then
  num_samples="$(validate_samples_tsv "${SAMPLES_TSV}")" || exit 1
else
  num_samples="$(validate_sample_pairs_tsv "${SAMPLE_PAIRS_TSV}")" || exit 1
fi

if [[ -z "${num_samples}" || ! "${num_samples}" =~ ^[0-9]+$ || "${num_samples}" -le 0 ]]; then
  echo "[ERROR] invalid sample count: ${num_samples}" >&2
  exit 1
fi

array_end=$((num_samples - 1))

if [[ "${PIPELINE_PHASE}" == "phase1" ]]; then
  log "pipeline=${PIPELINE_PHASE}, samples=${num_samples}, array=0-${array_end}%${MAX_PARALLEL}, mode=${MODE}, phase1_end_stage=${PHASE1_END_STAGE}"
else
  log "pipeline=${PIPELINE_PHASE}, samples=${num_samples}, array=0-${array_end}%${MAX_PARALLEL}, mode=${MODE}, end_stage=${END_STAGE}"
fi

sbatch \
  --export=ALL,PIPELINE_PHASE="${PIPELINE_PHASE}",SAMPLES_TSV="${SAMPLES_TSV}",SAMPLE_PAIRS_TSV="${SAMPLE_PAIRS_TSV}",MODE="${MODE}",ENABLE_CHECK_PAIRS="${ENABLE_CHECK_PAIRS}",END_STAGE="${END_STAGE}",ENABLE_CONTAMINATION="${ENABLE_CONTAMINATION}",ENABLE_ORIENTATION="${ENABLE_ORIENTATION}",ENABLE_ANNOTATION="${ENABLE_ANNOTATION}",PHASE1_END_STAGE="${PHASE1_END_STAGE}" \
  --array="0-${array_end}%${MAX_PARALLEL}" \
  "${ROOT}/run_sample_array.sbatch"
