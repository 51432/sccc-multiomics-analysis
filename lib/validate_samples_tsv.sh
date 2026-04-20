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
  header="$(head -n 1 "$tsv" | tr -d '\r')"

  local has_header=0
  local first_data_line=1
  if [[ "$header" == "$expected" ]]; then
    has_header=1
    first_data_line=2
  else
    # 兼容无表头文件：第一行可直接是数据（TAB 或空白分隔）
    if ! awk 'NR==1 { if (NF==3 && $1!="sample_id") exit 0; exit 1 }' "$tsv"; then
      echo "[ERROR] invalid header: $header" >&2
      echo "[ERROR] expected header: sample_id<TAB>input_R1<TAB>input_R2 (or a headerless 3-column file)" >&2
      return 1
    fi
    echo "[WARN] header not found; treating first line as data" >&2
  fi

  awk -v start_line="$first_data_line" '
    BEGIN { OFS="\t" }
    NR < start_line { next }
    {
      if (NF != 3) { printf("[ERROR] line=%d NF=%d (expected 3 columns)\n", NR, NF); err=1; next }
      if ($1=="" || $2=="" || $3=="") { printf("[ERROR] line=%d empty field\n", NR); err=1; next }
      if (seen[$1]++) { printf("[ERROR] duplicate sample_id at line=%d: %s\n", NR, $1); err=1 }
    }
    END { if (err) exit 1 }
  ' "$tsv" || return 1

  local n=0
  while read -r sid r1 r2 extra || [[ -n "${sid}${r1}${r2}${extra}" ]]; do
    [[ -z "${sid}${r1}${r2}${extra}" ]] && continue

    if [[ "$has_header" -eq 1 && "$sid" == "sample_id" && "$r1" == "input_R1" && "$r2" == "input_R2" && -z "$extra" ]]; then
      continue
    fi

    if [[ -n "$extra" ]]; then
      echo "[ERROR] sample=$sid expected exactly 3 columns" >&2
      return 1
    fi

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
