#!/usr/bin/env bash
set -euo pipefail

WGS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WGS_PIPELINE_DIR="$(cd "${WGS_LIB_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${WGS_PIPELINE_DIR}/../.." && pwd)"

DEFAULT_CONFIG="${WGS_PIPELINE_DIR}/config/paths.env"
REPO_CONFIG="${WGS_PIPELINE_DIR}/config/paths.repo.env"
EXAMPLE_CONFIG="${WGS_PIPELINE_DIR}/config/paths.example.env"

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

run_legacy_stage() {
  local script_name="$1"
  local script_path="${LEGACY_PIPELINE_DIR}/${script_name}"

  if [[ ! -f "${script_path}" ]]; then
    echo "[ERROR] Legacy stage missing: ${script_path}" >&2
    exit 1
  fi

  run_cmd bash "${script_path}"
}
