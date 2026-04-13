#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib.sh"

stage_ids=(00 01 02 03 04 05 06 07)

declare -A stage_labels=(
  [00]="export environment"
  [01]="check pairs"
  [02]="align"
  [03]="postprocess bam"
  [04]="call variants"
  [05]="filter and orient"
  [06]="annotation"
  [07]="downstream analysis"
)

declare -A stage_scripts=(
  [00]="00_export_pipeline_environment.sh"
  [01]="02a_check_pairs.sh"
  [02]="02b_align_and_sort_bam_to_ref.bwa.sh"
  [03]="03_merge_bams.sambamba.sh 04_markduplicates.sambamba.markdup.sh 05_run_bqsr.gatk.BaseRecalibrator.sh"
  [04]="06b_call_SNVs_and_indels.gatk.mutect2.sh"
  [05]="06c_check_crosscontamination.gatk.CalculateContamination.sh 06d_calc_f1r2.read_orientation.sh 07_read_orientation.gatk.LearnReadOrientationModel.sh 08_filter_somatic_var.gatk.FilterMutectCalls.sh"
  [06]="09a_variant_annotation.annovar.sh"
  [07]="10_run_analyses.signatures_and_TBM.sh"
)

is_valid_stage() {
  local s="$1"
  local sid
  for sid in "${stage_ids[@]}"; do
    [[ "${sid}" == "${s}" ]] && return 0
  done
  return 1
}

print_stage_table() {
  local sid
  for sid in "${stage_ids[@]}"; do
    printf "%s\t%s\t%s\n" "${sid}" "${stage_labels[${sid}]}" "${stage_scripts[${sid}]}"
  done
}

usage() {
  cat <<USAGE
Usage:
  $0 <stage_id> [--config FILE] [--dry-run]
  $0 --list

Stage IDs:
USAGE
  local sid
  for sid in "${stage_ids[@]}"; do
    printf "  %s %s\n" "${sid}" "${stage_labels[${sid}]}"
  done
  usage_common
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if [[ "$1" == "--list" ]]; then
  print_stage_table
  exit 0
fi

STAGE_ID="$1"
shift

if ! is_valid_stage "${STAGE_ID}"; then
  echo "[ERROR] Unknown stage_id: ${STAGE_ID}" >&2
  usage
  exit 1
fi

parse_common_args "$@"
load_config "${CONFIG_PATH}"

for script_name in ${stage_scripts[${STAGE_ID}]}; do
  run_legacy_stage "${script_name}"
done
