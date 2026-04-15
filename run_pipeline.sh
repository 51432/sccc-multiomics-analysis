#!/usr/bin/env bash
set -euo pipefail

# 批量处理 paired-end FASTQ：逐分片 fastp + 按样本合并

usage() {
  cat <<'USAGE'
用法:
  run_pipeline.sh -i samples.tsv -o /path/to/output -l /path/to/logs [-t 4] [--dry-run] [--force] [--skip-done]

参数:
  -i    输入 TSV 文件（必须包含表头: sample_id\tinput_R1\tinput_R2）
  -o    输出根目录（将创建 fastp_intermediate/, merged/, reports/）
  -l    日志目录（每个样本一个日志文件）
  -t    fastp 线程数，默认 4
  --dry-run    只打印命令，不执行
  --force      覆盖已存在输出
  --skip-done  若某样本 merged 结果已存在则跳过该样本
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
    -i)
      INPUT_TSV="${2:-}"
      shift 2
      ;;
    -o)
      OUT_ROOT="${2:-}"
      shift 2
      ;;
    -l)
      LOG_DIR="${2:-}"
      shift 2
      ;;
    -t)
      THREADS="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --skip-done)
      SKIP_DONE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
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

mkdir -p "$OUT_ROOT/fastp_intermediate" "$OUT_ROOT/merged" "$OUT_ROOT/reports"
mkdir -p "$LOG_DIR"

# 读取 TSV 并做格式/文件检查
# 说明：part 编号严格按 TSV 读取顺序累计（同 sample_id 第 N 次出现即 partN）。
declare -a record_samples=()
declare -a record_r1=()
declare -a record_r2=()
declare -a record_part=()

declare -A sample_count=()
declare -A sample_parts_r1=()
declare -A sample_parts_r2=()
declare -A sample_seen=()
declare -a sample_order=()

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

  # 跳过空行（全空）
  if [[ -z "${c1:-}" && -z "${c2:-}" && -z "${c3:-}" && -z "${extra:-}" ]]; then
    continue
  fi

  # 格式检查：必须正好三列
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
  count=${sample_count[$sample]:-0}
  count=$((count + 1))
  sample_count[$sample]="$count"
  part="$count"

  if [[ -z "${sample_seen[$sample]:-}" ]]; then
    sample_seen[$sample]=1
    sample_order+=("$sample")
  fi

  record_samples+=("$sample")
  record_r1+=("$c2")
  record_r2+=("$c3")
  record_part+=("$part")

done < "$INPUT_TSV"

if [[ ${#record_samples[@]} -eq 0 ]]; then
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

# 先确定哪些样本需要跳过（skip-done）
declare -A skip_sample=()
for sample in "${sample_order[@]}"; do
  merged_r1="$OUT_ROOT/merged/${sample}.R1.fastp.gz"
  merged_r2="$OUT_ROOT/merged/${sample}.R2.fastp.gz"
  if [[ $SKIP_DONE -eq 1 && -f "$merged_r1" && -f "$merged_r2" ]]; then
    skip_sample[$sample]=1
    echo "[INFO] skip-done: 样本 $sample 已有 merged 结果，跳过。"
  else
    skip_sample[$sample]=0
  fi
done

# 逐分片运行 fastp（严格按 TSV 顺序）
for idx in "${!record_samples[@]}"; do
  sample="${record_samples[$idx]}"
  in_r1="${record_r1[$idx]}"
  in_r2="${record_r2[$idx]}"
  part="${record_part[$idx]}"

  if [[ "${skip_sample[$sample]}" -eq 1 ]]; then
    continue
  fi

  out_r1="$OUT_ROOT/fastp_intermediate/${sample}.part${part}.R1.fastp.gz"
  out_r2="$OUT_ROOT/fastp_intermediate/${sample}.part${part}.R2.fastp.gz"
  report_dir="$OUT_ROOT/reports/$sample"
  html="$report_dir/${sample}.part${part}.fastp.html"
  json="$report_dir/${sample}.part${part}.fastp.json"

  mkdir -p "$report_dir"

  # 文件存在策略：
  # - 默认不覆盖，若存在则报错；
  # - --force 时先删除再重跑。
  for f in "$out_r1" "$out_r2" "$html" "$json"; do
    if [[ -e "$f" ]]; then
      if [[ $FORCE -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
          echo "[DRY-RUN][$sample] rm -f $f"
        else
          rm -f "$f"
        fi
      else
        echo "[ERROR] 输出文件已存在（使用 --force 可覆盖）: $f" >&2
        exit 1
      fi
    fi
  done

  run_cmd "$sample" fastp \
    --thread "$THREADS" \
    --in1 "$in_r1" --in2 "$in_r2" \
    --out1 "$out_r1" --out2 "$out_r2" \
    --html "$html" --json "$json"

  sample_parts_r1[$sample]="${sample_parts_r1[$sample]:-} $out_r1"
  sample_parts_r2[$sample]="${sample_parts_r2[$sample]:-} $out_r2"
done

# 按样本合并中间结果到 merged/
for sample in "${sample_order[@]}"; do
  if [[ "${skip_sample[$sample]}" -eq 1 ]]; then
    continue
  fi

  merged_r1="$OUT_ROOT/merged/${sample}.R1.fastp.gz"
  merged_r2="$OUT_ROOT/merged/${sample}.R2.fastp.gz"

  if [[ -e "$merged_r1" || -e "$merged_r2" ]]; then
    if [[ $FORCE -eq 1 ]]; then
      if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN][$sample] rm -f $merged_r1 $merged_r2"
      else
        rm -f "$merged_r1" "$merged_r2"
      fi
    else
      echo "[ERROR] merged 输出已存在（使用 --force 可覆盖）: $sample" >&2
      exit 1
    fi
  fi

  # 以 part1..partN 顺序检查并合并，确保顺序与 TSV 一致
  n_parts="${sample_count[$sample]}"
  r1_files=()
  r2_files=()
  for ((p=1; p<=n_parts; p++)); do
    f1="$OUT_ROOT/fastp_intermediate/${sample}.part${p}.R1.fastp.gz"
    f2="$OUT_ROOT/fastp_intermediate/${sample}.part${p}.R2.fastp.gz"
    if [[ ! -f "$f1" || ! -f "$f2" ]]; then
      echo "[ERROR] 合并前检查失败，缺少中间文件: $f1 或 $f2" >&2
      exit 1
    fi
    r1_files+=("$f1")
    r2_files+=("$f2")
  done

  # 这里使用 gzip 文件直接拼接（gzip 流拼接是合法的）
  cmd_r1="cat"
  for f in "${r1_files[@]}"; do
    cmd_r1+=" $(printf %q "$f")"
  done
  cmd_r1+=" > $(printf %q "$merged_r1")"

  cmd_r2="cat"
  for f in "${r2_files[@]}"; do
    cmd_r2+=" $(printf %q "$f")"
  done
  cmd_r2+=" > $(printf %q "$merged_r2")"

  run_shell_cmd "$sample" "$cmd_r1"
  run_shell_cmd "$sample" "$cmd_r2"
done

echo "[DONE] 流程完成。"
echo "  输出目录: $OUT_ROOT"
echo "  日志目录: $LOG_DIR"
