#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_STAGE_SCRIPT="${SCRIPT_DIR}/bin/run_stage.sh"

usage() {
  cat <<USAGE
Usage: $0 [--from STAGE] [--to STAGE] [--config FILE] [--dry-run]

Examples:
  $0 --dry-run
  $0 --from 03 --to 06 --config pipeline/wgs_somatic/config/paths.env
USAGE
}

FROM="00"
TO="07"
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      [[ $# -ge 2 ]] || { echo "[ERROR] --from requires stage id" >&2; exit 1; }
      FROM="$2"
      shift 2
      ;;
    --to)
      [[ $# -ge 2 ]] || { echo "[ERROR] --to requires stage id" >&2; exit 1; }
      TO="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

STAGES=(00 01 02 03 04 05 06 07)
from_idx=-1
to_idx=-1

for i in "${!STAGES[@]}"; do
  [[ "${STAGES[$i]}" == "${FROM}" ]] && from_idx=$i
  [[ "${STAGES[$i]}" == "${TO}" ]] && to_idx=$i
done

if [[ $from_idx -lt 0 ]]; then
  echo "[ERROR] Invalid --from stage: ${FROM}" >&2
  exit 1
fi
if [[ $to_idx -lt 0 ]]; then
  echo "[ERROR] Invalid --to stage: ${TO}" >&2
  exit 1
fi
if [[ $from_idx -gt $to_idx ]]; then
  echo "[ERROR] --from stage must come before or equal to --to stage" >&2
  exit 1
fi

for ((i=from_idx; i<=to_idx; i++)); do
  bash "${RUN_STAGE_SCRIPT}" "${STAGES[$i]}" "${ARGS[@]}"
done
