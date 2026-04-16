#!/usr/bin/env bash

validate_samples_tsv() {
  local tsv="$1"
  [[ -f "$tsv" ]] || { echo "[ERROR] not found: $tsv" >&2; return 1; }

  local expected=$'sample_id\tinput_R1\tinput_R2'
  local header
  header="$(head -n 1 "$tsv")"
  [[ "$header" == "$expected" ]] || {
    echo "[ERROR] invalid header: $header" >&2
    return 1
  }

  awk -F'\t' '
    NR==1{next}
    NF!=3 {printf("[ERROR] line=%d NF=%d\n", NR, NF); err=1; next}
    $1=="" || $2=="" || $3=="" {printf("[ERROR] line=%d empty field\n", NR); err=1}
    { if(seen[$1]++) {printf("[ERROR] duplicate sample_id at line=%d: %s\n", NR, $1); err=1} }
    END{ if(err) exit 1 }
  ' "$tsv"

  local n=0
  while IFS=$'\t' read -r sid r1 r2; do
    [[ "$sid" == "sample_id" ]] && continue
    [[ -r "$r1" ]] || { echo "[ERROR] $sid R1 not readable: $r1" >&2; return 1; }
    [[ -r "$r2" ]] || { echo "[ERROR] $sid R2 not readable: $r2" >&2; return 1; }
    n=$((n+1))
  done < "$tsv"

  [[ "$n" -gt 0 ]] || { echo "[ERROR] no samples" >&2; return 1; }
  echo "$n"
}
