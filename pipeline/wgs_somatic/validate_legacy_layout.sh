#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_STAGE_SCRIPT="${SCRIPT_DIR}/bin/run_stage.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/bin/lib.sh"

parse_common_args "$@"
load_config "${CONFIG_PATH}"

missing=0
while IFS=$'\t' read -r stage_id _ scripts; do
  for script in ${scripts}; do
    full_path="${LEGACY_PIPELINE_DIR}/${script}"
    if [[ ! -f "${full_path}" ]]; then
      echo "[MISSING] stage=${stage_id} file=${full_path}"
      missing=1
    else
      echo "[OK] stage=${stage_id} file=${full_path}"
    fi
  done
done < <(bash "${RUN_STAGE_SCRIPT}" --list)

if [[ "${missing}" == "1" ]]; then
  exit 1
fi
