#!/usr/bin/env bash


ROOT="$(cd "$(dirname "$0")" && pwd)"
source "${ROOT}/config/00_config.sh"
source "${ROOT}/lib/steps_somatic_phase1.sh"          # phase1

task_id="${SLURM_ARRAY_TASK_ID:?SLURM_ARRAY_TASK_ID is not set}"
line_no=$((task_id + 2))

line="$(awk -v n="${line_no}" 'NR==n{print; exit}' "${SAMPLES_TSV}")"
[[ -n "${line}" ]] || { echo "[ERROR] no line for task_id=${task_id}" >&2; exit 1; }

IFS=$'\t' read -r sample_id input_R1 input_R2 <<< "${line}"

sample_log_dir="${LOG_DIR}/sample"
mkdir -p "${sample_log_dir}" "${STATUS_DIR}/${sample_id}"
sample_log="${sample_log_dir}/${sample_id}.pipeline.log"

exec > >(tee -a "${sample_log}") 2>&1

log "task_id=${task_id}, sample=${sample_id}, mode=${MODE}"
log "R1=${input_R1}"
log "R2=${input_R2}"

run_check_pairs "${sample_id}" "${input_R1}" "${input_R2}"
run_align_sort "${sample_id}"
run_markduplicates "${sample_id}"
run_bqsr "${sample_id}"

touch "${STATUS_DIR}/${sample_id}/phase1.done"
log "[DONE] phase1 completed for sample=${sample_id}"
