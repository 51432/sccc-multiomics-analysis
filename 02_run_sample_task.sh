#!/usr/bin/env bash

ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config/00_config.sh"
source "${ROOT}/lib/steps_phase1_preprocess.sh"   # 前半段（保留）
source "${ROOT}/lib/steps_somatic.sh"          # 后半段（新增）

task_id="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is not set}"
line_no=$((task_id + 2))

line="$(awk -v n="${line_no}" 'NR==n{print; exit}' "${SAMPLES_TSV}")"
[[ -n "${line}" ]] || { echo "[ERROR] no line for task_id=${task_id}" >&2; exit 1; }

if [[ "${PIPELINE_PHASE}" == "phase1" ]]; then
  IFS=$'\t' read -r sample_id input_R1 input_R2 <<< "${line}"
else
  IFS=$'\t' read -r sample_id tumor_bam normal_bam <<< "${line}"
fi

sample_log_dir="${LOG_DIR}/sample"
if [[ ! -d "${sample_log_dir}" ]]; then
  mkdir -p "${sample_log_dir}"
fi
if [[ ! -d "${STATUS_DIR}/${sample_id}" ]]; then
  mkdir -p "${STATUS_DIR}/${sample_id}"
fi
sample_log="${sample_log_dir}/${sample_id}.pipeline.log"

exec > >(tee -a "${sample_log}") 2>&1

log "task_id=${task_id}, sample=${sample_id}, mode=${MODE}, pipeline=${PIPELINE_PHASE}"

if [[ "${PIPELINE_PHASE}" == "phase1" ]]; then
  log "R1=${input_R1}"
  log "R2=${input_R2}"
  log "phase1_end_stage=${PHASE1_END_STAGE}"

  run_check_pairs "${sample_id}" "${input_R1}" "${input_R2}"
  run_align_sort "${sample_id}"
  run_markduplicates "${sample_id}"

  if [[ "${PHASE1_END_STAGE}" == "bqsr" ]]; then
    run_bqsr "${sample_id}"
  else
    log "[SKIP] bqsr disabled because phase1_end_stage=${PHASE1_END_STAGE}"
  fi

  touch "${STATUS_DIR}/${sample_id}/phase1.done"
  log "[DONE] phase1 completed for sample=${sample_id}"
else
  log "tumor_bam=${tumor_bam}"
  log "normal_bam=${normal_bam}"
  log "end_stage=${END_STAGE}, contamination=${ENABLE_CONTAMINATION}, orientation=${ENABLE_ORIENTATION}, annotation=${ENABLE_ANNOTATION}"

  run_phase2_somatic_pipeline "${sample_id}" "${tumor_bam}" "${normal_bam}"
fi
