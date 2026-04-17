#!/usr/bin/env bash

# 加载统一配置（参考路径、工具路径、输出目录都在这里定义）
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config/00_config.sh"

###############################################################################
# step1: check_pairs（当前先直通，不做额外拆分）
# 输入:
#   $2 = R1 fastq.gz
#   $3 = R2 fastq.gz
# 输出:
#   仅设置环境变量 SAMPLE_R1 / SAMPLE_R2，供后续步骤使用
###############################################################################
run_check_pairs() {
  local sid="$1"
  local r1="$2"
  local r2="$3"

  mkdir -p "${STATUS_DIR}/${sid}"

  # 简化：直接使用输入 FASTQ，不做额外处理
  export SAMPLE_R1="${r1}"
  export SAMPLE_R2="${r2}"

  touch "${STATUS_DIR}/${sid}/01_check_pairs.done"
  log "[DONE] check_pairs (passthrough) sample=${sid}"
}

###############################################################################
# step2: bwa-mem2 mem + sambamba sort
# 输入:
#   SAMPLE_R1 / SAMPLE_R2
# 输出:
#   ${ALIGNED_DIR}/${sid}.sorted.bam
#   ${ALIGNED_DIR}/${sid}.sorted.bam.bai
###############################################################################
run_align_sort() {
  local sid="$1"

  mkdir -p "${ALIGNED_DIR}" "${TMP_DIR}/${sid}" "${STATUS_DIR}/${sid}"

  local unsorted_bam="${ALIGNED_DIR}/${sid}.bam"
  local sorted_bam="${ALIGNED_DIR}/${sid}.sorted.bam"

  log "[RUN] align sample=${sid}"
  log "[PATH] R1=${SAMPLE_R1}"
  log "[PATH] R2=${SAMPLE_R2}"
  log "[PATH] REF=${REFERENCE}"
  log "[OUT ] unsorted_bam=${unsorted_bam}"
  log "[OUT ] sorted_bam=${sorted_bam}"

  "${BWA_MEM2_BIN}" mem \
    -t "${SLURM_CPUS_PER_TASK:-8}" \
    -R "@RG\tID:${sid}\tPL:ILLUMINA\tSM:${sid}" \
    "${REFERENCE}" \
    "${SAMPLE_R1}" \
    "${SAMPLE_R2}" \
  | "${SAMBAMBA_BIN}" view -S -f bam -o "${unsorted_bam}" /dev/stdin

  "${SAMBAMBA_BIN}" sort \
    --tmpdir="${TMP_DIR}/${sid}" \
    -m 20GB \
    -t "${SLURM_CPUS_PER_TASK:-8}" \
    -o "${sorted_bam}" \
    "${unsorted_bam}"

  "${SAMTOOLS_BIN}" index "${sorted_bam}"

  touch "${STATUS_DIR}/${sid}/02_align_sort.done"
  log "[DONE] align_sort sample=${sid}"
}

###############################################################################
# step3: sambamba markdup
# 输入:
#   ${ALIGNED_DIR}/${sid}.sorted.bam
# 输出:
#   ${PREPROC_DIR}/${sid}.markdup.bam
#   ${PREPROC_DIR}/${sid}.markdup.bai
###############################################################################
run_markduplicates() {
  local sid="$1"

  mkdir -p "${PREPROC_DIR}" "${TMP_DIR}/${sid}" "${STATUS_DIR}/${sid}"

  local in_bam="${ALIGNED_DIR}/${sid}.sorted.bam"
  local out_bam="${PREPROC_DIR}/${sid}.markdup.bam"

  log "[RUN] markdup sample=${sid}"
  log "[PATH] in_bam=${in_bam}"
  log "[OUT ] out_bam=${out_bam}"

  "${SAMBAMBA_BIN}" markdup \
    --tmpdir="${TMP_DIR}/${sid}" \
    -t "${SLURM_CPUS_PER_TASK:-8}" \
    "${in_bam}" \
    "${out_bam}"

  "${SAMTOOLS_BIN}" index "${out_bam}"

  touch "${STATUS_DIR}/${sid}/03_markdup.done"
  log "[DONE] markdup sample=${sid}"
}

###############################################################################
# step4: BQSR
# 输入:
#   ${PREPROC_DIR}/${sid}.markdup.bam
# 输出:
#   ${BQSR_DIR}/${sid}.bqsr.bam
#   ${BQSR_DIR}/${sid}.bqsr.bai
###############################################################################
run_bqsr() {
  local sid="$1"

  mkdir -p "${BQSR_DIR}" "${TMP_DIR}/${sid}" "${STATUS_DIR}/${sid}"

  local in_bam="${PREPROC_DIR}/${sid}.markdup.bam"
  local table="${TMP_DIR}/${sid}/${sid}.bqsr.table"
  local out_bam="${BQSR_DIR}/${sid}.bqsr.bam"

  log "[RUN] bqsr sample=${sid}"
  log "[PATH] in_bam=${in_bam}"
  log "[PATH] intervals=${INTERVALS}"
  log "[PATH] known_snps=${KNOWNSITES_SNPS}"
  log "[PATH] known_indels=${KNOWNSITES_INDELS}"
  log "[OUT ] recal_table=${table}"
  log "[OUT ] out_bam=${out_bam}"

  "${GATK_BIN}" --java-options "-Xmx16G -XX:+UseParallelGC -XX:ParallelGCThreads=12 -Djava.io.tmpdir=${TMP_DIR}/${sid}" BaseRecalibrator \
    -R "${REFERENCE}" \
    -L "${INTERVALS}" \
    --known-sites "${KNOWNSITES_SNPS}" \
    --known-sites "${KNOWNSITES_INDELS}" \
    -I "${in_bam}" \
    -O "${table}"

  "${GATK_BIN}" --java-options "-Xmx16G -XX:+UseParallelGC -XX:ParallelGCThreads=12 -Djava.io.tmpdir=${TMP_DIR}/${sid}" ApplyBQSR \
    -R "${REFERENCE}" \
    -I "${in_bam}" \
    --bqsr-recal-file "${table}" \
    -O "${out_bam}" \
    --create-output-bam-index true

  touch "${STATUS_DIR}/${sid}/04_bqsr.done"
  log "[DONE] bqsr sample=${sid}"
}
