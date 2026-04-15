#!/usr/bin/env bash
set -euo pipefail

# 批量处理 paired-end FASTQ：先按样本合并分片，再执行 fastp

usage() {
  cat <<'USAGE'
用法:
  run_pipeline.sh -i samples.tsv -o /path/to/output -l /path/to/logs [-t 4] [--dry-run] [--force] [--skip-done]

参数:
  -i    输入 TSV 文件（必须包含表头: sample_id\tinput_R1\tinput_R2）
  -o    输出根目录（将创建 merged/, fastq/, reports_fastq/）
  -l    日志目录（每个样本一个日志文件）
  -t    fastp 线程数，默认 4
  --dry-run    只打印命令，不执行
  --force      强制重建 merged 与 fastp 结果
  --skip-done  若某样本最终 fastp 结果已存在则跳过
  -h, --help   显示帮助
USAGE
}

INPUT_TSV=""
OUT_ROOT=""
LOG_DIR=""
THREADS=4
DRY_RUN=0
FORCE=0
SKIP_DONE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) INPUT_TSV="${2:-}"; shift 2 ;;
    -o) OUT_ROOT="${2:-}"; shift 2 ;;
    -l) LOG_DIR="${2:-}"; shift 2 ;;
    -t) THREADS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --skip-done) SKIP_DONE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "[ERROR] 未知参数: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INPUT_TSV" || -z "$OUT_ROOT" || -z "$LOG_DIR" ]]; then
  echo "[ERROR] -i/-o/-l 为必填参数。" >&2
  usage >&2
  exit 1
fi

if ! [[ "$THREADS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR] -t 必须是正整数，当前: $THREADS" >&2
  exit 1
fi

if ! command -v fastp >/dev/null 2>&1; then
  echo "[ERROR] 未找到 fastp，请先安装并确保在 PATH 中。" >&2
  exit 1
fi

if [[ ! -f "$INPUT_TSV" ]]; then
  echo "[ERROR] 输入 TSV 不存在: $INPUT_TSV" >&2
  exit 1
fi

ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
  fi
}

# 目录仅在不存在时创建，避免误操作已有数据目录
ensure_dir "$OUT_ROOT/merged"
ensure_dir "$OUT_ROOT/fastq"
ensure_dir "$OUT_ROOT/reports_fastq"
ensure_dir "$LOG_DIR"

# 读取 TSV 并检查格式；同一个 sample_id 的分片顺序严格按 TSV 顺序
# 这里存的是“原始分片 FASTQ 列表”，后续先合并再跑 fastp。
declare -A sample_seen=()
declare -a sample_order=()
declare -A sample_r1_list=()
declare -A sample_r2_list=()

line_no=0
while IFS=$'\t' read -r c1 c2 c3 extra; do
  ((line_no+=1))

  if [[ $line_no -eq 1 ]]; then
    if [[ "$c1" != "sample_id" || "$c2" != "input_R1" || "$c3" != "input_R2" || -n "${extra:-}" ]]; then
      echo "[ERROR] TSV 表头必须且仅能是: sample_id<TAB>input_R1<TAB>input_R2" >&2
      exit 1
    fi
    continue
  fi

  if [[ -z "${c1:-}" && -z "${c2:-}" && -z "${c3:-}" && -z "${extra:-}" ]]; then
    continue
  fi

  if [[ -z "${c1:-}" || -z "${c2:-}" || -z "${c3:-}" || -n "${extra:-}" ]]; then
    echo "[ERROR] TSV 第 ${line_no} 行格式错误（必须正好三列且非空）。" >&2
    exit 1
  fi

  if [[ ! -f "$c2" ]]; then
    echo "[ERROR] TSV 第 ${line_no} 行 input_R1 文件不存在: $c2" >&2
    exit 1
  fi
  if [[ ! -f "$c3" ]]; then
    echo "[ERROR] TSV 第 ${line_no} 行 input_R2 文件不存在: $c3" >&2
    exit 1
  fi

  sample="$c1"

  if [[ -z "${sample_seen[$sample]:-}" ]]; then
    sample_seen[$sample]=1
    sample_order+=("$sample")
  fi

  if [[ -z "${sample_r1_list[$sample]:-}" ]]; then
    sample_r1_list[$sample]="$c2"
    sample_r2_list[$sample]="$c3"
  else
    sample_r1_list[$sample]+=$'\n'"$c2"
    sample_r2_list[$sample]+=$'\n'"$c3"
  fi
done < "$INPUT_TSV"

if [[ ${#sample_order[@]} -eq 0 ]]; then
  echo "[ERROR] 输入 TSV 没有有效数据行。" >&2
  exit 1
fi

run_cmd() {
  local sample="$1"
  shift
  local cmd=("$@")
  local log_file="$LOG_DIR/${sample}.log"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf '[DRY-RUN][%s] ' "$sample"
    printf '%q ' "${cmd[@]}"
    printf '\n'
  else
    printf '[%s] ' "$(date '+%F %T')" >> "$log_file"
    printf '%q ' "${cmd[@]}" >> "$log_file"
    printf '\n' >> "$log_file"
    "${cmd[@]}" >> "$log_file" 2>&1
  fi
}

run_shell_cmd() {
  local sample="$1"
  local cmd_str="$2"
  local log_file="$LOG_DIR/${sample}.log"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[DRY-RUN][$sample] $cmd_str"
  else
    echo "[$(date '+%F %T')] $cmd_str" >> "$log_file"
    bash -c "$cmd_str" >> "$log_file" 2>&1
  fi
}

# 每个样本：先合并 raw fastq.gz，再做一次 fastp
for sample in "${sample_order[@]}"; do
  raw_merged_r1="$OUT_ROOT/merged/${sample}.R1.merged.fastq.gz"
  raw_merged_r2="$OUT_ROOT/merged/${sample}.R2.merged.fastq.gz"
  final_r1="$OUT_ROOT/fastq/${sample}.R1.fastp.gz"
  final_r2="$OUT_ROOT/fastq/${sample}.R2.fastp.gz"
  report_dir="$OUT_ROOT/reports_fastq/$sample"
  report_html="$report_dir/${sample}.fastp.html"
  report_json="$report_dir/${sample}.fastp.json"

  if [[ $SKIP_DONE -eq 1 && -f "$final_r1" && -f "$final_r2" ]]; then
    echo "[INFO] skip-done: 样本 $sample 已有最终 fastp 结果，跳过。"
    continue
  fi

  ensure_dir "$report_dir"

  # 合并前再次检查原始分片输入都存在（防止长流程中输入被移动）
  r1_q=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || { echo "[ERROR] 合并前检查失败，缺少 R1 分片: $f" >&2; exit 1; }
    r1_q+=" $(printf '%q' "$f")"
  done <<< "${sample_r1_list[$sample]}"

  r2_q=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || { echo "[ERROR] 合并前检查失败，缺少 R2 分片: $f" >&2; exit 1; }
    r2_q+=" $(printf '%q' "$f")"
  done <<< "${sample_r2_list[$sample]}"

  # 合并策略（可断点续跑）：
  # 1) merged R1/R2 都存在且未 --force：跳过合并；
  # 2) 否则执行合并（若 --force 或部分缺失，则重建合并文件）。
  need_merge=1
  if [[ -f "$raw_merged_r1" && -f "$raw_merged_r2" && $FORCE -eq 0 ]]; then
    need_merge=0
    echo "[INFO] 样本 $sample 已存在 merged fastq.gz，跳过合并。"
  fi

  if [[ $need_merge -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[DRY-RUN][$sample] rm -f $raw_merged_r1 $raw_merged_r2"
    else
      rm -f "$raw_merged_r1" "$raw_merged_r2"
    fi
    cmd_merge_r1="cat${r1_q} > $(printf '%q' "$raw_merged_r1")"
    cmd_merge_r2="cat${r2_q} > $(printf '%q' "$raw_merged_r2")"
    run_shell_cmd "$sample" "$cmd_merge_r1"
    run_shell_cmd "$sample" "$cmd_merge_r2"
  fi

  # fastp 结果若已存在则默认跳过，便于中断后续跑；--force 时重跑。
  if [[ -f "$final_r1" && -f "$final_r2" && $FORCE -eq 0 ]]; then
    echo "[INFO] 样本 $sample 已存在 fastp 结果，跳过 fastp。"
    continue
  fi
  if [[ $FORCE -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[DRY-RUN][$sample] rm -f $final_r1 $final_r2 $report_html $report_json"
    else
      rm -f "$final_r1" "$final_r2" "$report_html" "$report_json"
    fi
  fi

  # 对合并后的样本级 FASTQ 跑一次 fastp
  run_cmd "$sample" fastp \
    --thread "$THREADS" \
    --in1 "$raw_merged_r1" --in2 "$raw_merged_r2" \
    --out1 "$final_r1" --out2 "$final_r2" \
    --html "$report_html" --json "$report_json"
done

echo "[DONE] 流程完成。"
echo "  输出目录: $OUT_ROOT"
echo "  日志目录: $LOG_DIR"
