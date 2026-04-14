#!/usr/bin/env bash
set -euo pipefail

WGS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WGS_PIPELINE_DIR="$(cd "${WGS_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WGS_PIPELINE_DIR}/../.." && pwd)"

DEFAULT_CONFIG="${WGS_PIPELINE_DIR}/config/paths.env"
REPO_CONFIG="${WGS_PIPELINE_DIR}/config/paths.repo.env"
EXAMPLE_CONFIG="${WGS_PIPELINE_DIR}/config/paths.example.env"

declare -A LEGACY_SCRIPT_STAGE_MAP=(
  [00_export_pipeline_environment.sh]="00"
  [02a_check_pairs.sh]="01"
  [02b_align_and_sort_bam_to_ref.bwa.sh]="02"
  [03_merge_bams.sambamba.sh]="03"
  [04_markduplicates.sambamba.markdup.sh]="03"
  [05_run_bqsr.gatk.BaseRecalibrator.sh]="03"
  [06b_call_SNVs_and_indels.gatk.mutect2.sh]="04"
  [06c_check_crosscontamination.gatk.CalculateContamination.sh]="05"
  [06d_calc_f1r2.read_orientation.sh]="05"
  [07_read_orientation.gatk.LearnReadOrientationModel.sh]="05"
  [08_filter_somatic_var.gatk.FilterMutectCalls.sh]="05"
  [09a_variant_annotation.annovar.sh]="06"
  [10_run_analyses.signatures_and_TBM.sh]="07"
)

usage_common() {
  cat <<USAGE
Usage: [--config FILE] [--dry-run]

Options:
  --config FILE   Path to env config file.
                  Default priority: paths.env -> paths.repo.env -> paths.example.env
  --dry-run       Print commands without executing them.
  -h, --help      Show help.
USAGE
}

parse_common_args() {
  CONFIG_PATH="${DEFAULT_CONFIG}"
  DRY_RUN="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        if [[ $# -lt 2 ]]; then
          echo "[ERROR] --config requires a file path." >&2
          exit 1
        fi
        CONFIG_PATH="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="1"
        shift
        ;;
      -h|--help)
        usage_common
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        echo "[ERROR] Unknown option: $1" >&2
        usage_common >&2
        exit 1
        ;;
      *)
        break
        ;;
    esac
  done

  REMAINING_ARGS=("$@")
}

resolve_config_path() {
  local requested="$1"

  if [[ -f "${requested}" ]]; then
    echo "${requested}"
    return
  fi

  if [[ "${requested}" != "${DEFAULT_CONFIG}" ]]; then
    echo "[ERROR] Requested config not found: ${requested}" >&2
    exit 1
  fi

  if [[ -f "${DEFAULT_CONFIG}" ]]; then
    echo "${DEFAULT_CONFIG}"
    return
  fi

  if [[ -f "${REPO_CONFIG}" ]]; then
    echo "${REPO_CONFIG}"
    return
  fi

  if [[ -f "${EXAMPLE_CONFIG}" ]]; then
    echo "[WARN] No concrete config found; falling back to example config." >&2
    echo "${EXAMPLE_CONFIG}"
    return
  fi

  echo "[ERROR] No config available. Checked: ${DEFAULT_CONFIG}, ${REPO_CONFIG}, ${EXAMPLE_CONFIG}" >&2
  exit 1
}

load_config() {
  local requested_cfg="$1"
  local resolved_cfg
  resolved_cfg="$(resolve_config_path "${requested_cfg}")"

  # shellcheck disable=SC1090
  source "${resolved_cfg}"

  if [[ -z "${LEGACY_PIPELINE_DIR:-}" ]]; then
    LEGACY_PIPELINE_DIR="${REPO_ROOT}/somatic-mutation-analysis_bash_pipeline-main"
  fi

  if [[ ! -d "${LEGACY_PIPELINE_DIR}" ]]; then
    if [[ -d "${REPO_ROOT}/somatic-mutation-analysis_bash_pipeline-main" ]]; then
      echo "[WARN] LEGACY_PIPELINE_DIR not found (${LEGACY_PIPELINE_DIR}); using repo-local legacy pipeline." >&2
      LEGACY_PIPELINE_DIR="${REPO_ROOT}/somatic-mutation-analysis_bash_pipeline-main"
    else
      echo "[ERROR] LEGACY_PIPELINE_DIR does not exist: ${LEGACY_PIPELINE_DIR}" >&2
      exit 1
    fi
  fi
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "[RUN] $*"
    "$@"
  fi
}

legacy_stage_id_for_script() {
  local script_name="$1"
  echo "${LEGACY_SCRIPT_STAGE_MAP[${script_name}]:-unknown}"
}

is_stage_allowed() {
  local stage_id="$1"
  local allowed="${WGS_ALLOWED_STAGE_IDS:-}"

  if [[ -z "${allowed}" ]]; then
    return 0
  fi

  [[ " ${allowed} " == *" ${stage_id} "* ]]
}

legacy_qsub() {
  local target_script=""
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == *.sh ]]; then
      target_script="${arg##*/}"
    fi
  done

  if [[ "${WGS_ENFORCE_STAGE_BOUNDS:-0}" == "1" && -n "${target_script}" ]]; then
    local target_stage
    target_stage="$(legacy_stage_id_for_script "${target_script}")"
    if ! is_stage_allowed "${target_stage}"; then
      echo "[WARN] Blocked qsub for downstream stage ${target_stage} (${target_script}) while enforcing stage bounds: ${WGS_ALLOWED_STAGE_IDS}" >&2
      return 0
    fi
  fi

  command qsub "$@"
}

export -f legacy_qsub
export -f legacy_stage_id_for_script
export -f is_stage_allowed

run_legacy_stage() {
  local script_name="$1"
  local script_path="${LEGACY_PIPELINE_DIR}/${script_name}"

  if [[ ! -f "${script_path}" ]]; then
    echo "[ERROR] Legacy stage missing: ${script_path}" >&2
    exit 1
  fi

  export pipeline_dir="${LEGACY_PIPELINE_DIR}"
  export mode="${mode:-${MODE:-wgs}}"
  export sample="${sample:-${SAMPLE:-}}"
  export tumor="${tumor:-${TUMOR:-}}"
  export normal="${normal:-${NORMAL:-}}"
  export organism="${organism:-${ORGANISM:-hsapiens}}"
  export genome="${genome:-${GENOME:-hg38}}"

  if [[ "${WGS_ENFORCE_STAGE_BOUNDS:-0}" == "1" ]]; then
    export BASH_ENV="${WGS_LIB_DIR}/legacy_runtime_env.sh"
  fi

  run_cmd bash "${script_path}"
}
