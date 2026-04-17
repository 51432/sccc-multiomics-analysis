#!/usr/bin/env bash

# 统一错误输出函数（满足 pair 表格式要求）
_emit_pair_error() {
  local line_no="$1"
  local sid="$2"
  local msg="$3"
  echo "[ERROR] line=${line_no} sample_id=${sid} message=${msg}" >&2
}

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

validate_sample_pairs_tsv() {
  local tsv="$1"
  [[ -f "$tsv" ]] || { _emit_pair_error 0 "NA" "file not found: ${tsv}"; return 1; }

  local expected=$'sample_id\ttumor_bam\tnormal_bam'
  local header
  header="$(head -n 1 "$tsv")"
  [[ "$header" == "$expected" ]] || {
    _emit_pair_error 1 "NA" "invalid header, expected: sample_id\\ttumor_bam\\tnormal_bam"
    return 1
  }

  local n=0
  local line_no=1
  local has_error=0
  declare -A seen_ids=()

  while IFS=$'\t' read -r sid tumor_bam normal_bam extra || [[ -n "${sid}${tumor_bam}${normal_bam}${extra}" ]]; do
    line_no=$((line_no + 1))

    # 跳过空行，但记为格式错误（保证严格 3 列）
    if [[ -z "${sid}${tumor_bam}${normal_bam}${extra}" ]]; then
      _emit_pair_error "${line_no}" "NA" "empty line is not allowed"
      has_error=1
      continue
    fi

    if [[ -n "${extra}" ]]; then
      _emit_pair_error "${line_no}" "${sid:-NA}" "expected exactly 3 TAB-separated columns"
      has_error=1
      continue
    fi

    # 若不是 TAB 分隔，read 到的 tumor_bam/normal_bam 会为空，这里统一按列数错误处理
    if [[ -z "${sid}" || -z "${tumor_bam}" || -z "${normal_bam}" ]]; then
      _emit_pair_error "${line_no}" "${sid:-NA}" "expected exactly 3 TAB-separated columns"
      has_error=1
      continue
    fi

    if [[ -n "${seen_ids[$sid]:-}" ]]; then
      _emit_pair_error "${line_no}" "${sid}" "duplicate sample_id"
      has_error=1
      continue
    fi
    seen_ids["$sid"]=1

    if [[ "${tumor_bam}" == "${normal_bam}" ]]; then
      _emit_pair_error "${line_no}" "${sid}" "tumor_bam and normal_bam must be different"
      has_error=1
    fi

    if [[ ! -r "${tumor_bam}" ]]; then
      _emit_pair_error "${line_no}" "${sid}" "tumor_bam not readable: ${tumor_bam}"
      has_error=1
    fi

    if [[ ! -r "${normal_bam}" ]]; then
      _emit_pair_error "${line_no}" "${sid}" "normal_bam not readable: ${normal_bam}"
      has_error=1
    fi

    n=$((n + 1))
  done < <(tail -n +2 "$tsv")

  if [[ "$n" -le 0 ]]; then
    _emit_pair_error 2 "NA" "no sample pairs found"
    return 1
  fi

  [[ "$has_error" -eq 0 ]] || return 1
  echo "$n"
}
