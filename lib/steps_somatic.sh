#!/usr/bin/env bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/config/00_config.sh"

# 阶段顺序：数字越小越早
_stage_rank() {
  case "$1" in
    mutect2) echo 1 ;;
    contamination) echo 2 ;;
    orientation) echo 3 ;;
    filter) echo 4 ;;
    annotation) echo 5 ;;
    *) echo 999 ;;
  esac
}

_should_run_by_end_stage() {
  local stage="$1"
  [[ "$(_stage_rank "${stage}")" -le "$(_stage_rank "${END_STAGE}")" ]]
}

_should_run_contamination() {
  [[ "${ENABLE_CONTAMINATION}" == "1" ]] && _should_run_by_end_stage contamination
}

_should_run_orientation() {
  [[ "${ENABLE_ORIENTATION}" == "1" ]] && _should_run_by_end_stage orientation
}

_should_run_annotation() {
  [[ "${ENABLE_ANNOTATION}" == "1" ]] && _should_run_by_end_stage annotation
}

_get_bam_sample_name() {
  local bam="$1"
  local sm
  sm="$(${SAMTOOLS_BIN} view -H "${bam}" \
    | awk -F'\t' '/^@RG/{for(i=1;i<=NF;i++){if($i ~ /^SM:/){gsub(/^SM:/,"",$i); print $i; exit}}}')"

  [[ -n "${sm}" ]] || {
    echo "[ERROR] cannot parse SM tag from BAM header: ${bam}" >&2
    return 1
  }

  echo "${sm}"
}

run_mutect2() {
  local sid="$1"
  local tumor_bam="$2"
  local normal_bam="$3"

  mkdir -p "${MUTECT2_DIR}" "${F1R2_DIR}" "${STATUS_DIR}/${sid}" "${TMP_DIR}/${sid}"

  local tumor_sm normal_sm
  tumor_sm="$(_get_bam_sample_name "${tumor_bam}")"
  normal_sm="$(_get_bam_sample_name "${normal_bam}")"

  local out_vcf="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz"
  local out_stats="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz.stats"
  local out_f1r2="${F1R2_DIR}/${sid}.f1r2.tar.gz"

  log "[RUN] mutect2 sample=${sid}"
  log "[PATH] tumor_bam=${tumor_bam} (SM=${tumor_sm})"
  log "[PATH] normal_bam=${normal_bam} (SM=${normal_sm})"
  log "[PATH] intervals=${INTERVALS}"
  log "[PATH] gnomad=${GNOMAD_RESOURCE}"

  local cmd=(
    "${GATK_BIN}" --java-options "-Xmx24G -XX:+UseParallelGC -Djava.io.tmpdir=${TMP_DIR}/${sid}"
    Mutect2
    -R "${REFERENCE}"
    -L "${INTERVALS}"
    -I "${tumor_bam}" -tumor "${tumor_sm}"
    -I "${normal_bam}" -normal "${normal_sm}"
    --germline-resource "${GNOMAD_RESOURCE}"
    --f1r2-tar-gz "${out_f1r2}"
    -O "${out_vcf}"
  )

  cmd+=(--panel-of-normals "${GATK_PON}")
  log "[PATH] pon=${GATK_PON}"

  "${cmd[@]}"

  [[ -r "${out_stats}" ]] || {
    echo "[ERROR] mutect2 stats not found: ${out_stats}" >&2
    return 1
  }

  touch "${STATUS_DIR}/${sid}/10_mutect2.done"
  log "[DONE] mutect2 sample=${sid}"
}

run_contamination() {
  local sid="$1"
  local tumor_bam="$2"
  local normal_bam="$3"

  mkdir -p "${CONTAM_DIR}" "${STATUS_DIR}/${sid}" "${TMP_DIR}/${sid}"

  local tumor_pileups="${CONTAM_DIR}/${sid}.tumor.pileups.table"
  local normal_pileups="${CONTAM_DIR}/${sid}.normal.pileups.table"
  local contamination_table="${CONTAM_DIR}/${sid}.contamination.table"
  local segmentation_table="${CONTAM_DIR}/${sid}.segments.table"

  log "[RUN] contamination sample=${sid}"

  "${GATK_BIN}" --java-options "-Xmx12G -Djava.io.tmpdir=${TMP_DIR}/${sid}" GetPileupSummaries \
    -R "${REFERENCE}" \
    -I "${tumor_bam}" \
    -V "${GNOMAD_RESOURCE}" \
    -L "${INTERVALS_BED}" \
    -O "${tumor_pileups}"

  "${GATK_BIN}" --java-options "-Xmx12G -Djava.io.tmpdir=${TMP_DIR}/${sid}" GetPileupSummaries \
    -R "${REFERENCE}" \
    -I "${normal_bam}" \
    -V "${GNOMAD_RESOURCE}" \
    -L "${INTERVALS_BED}" \
    -O "${normal_pileups}"

  "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}" CalculateContamination \
    -I "${tumor_pileups}" \
    -matched "${normal_pileups}" \
    -O "${contamination_table}" \
    --tumor-segmentation "${segmentation_table}"

  touch "${STATUS_DIR}/${sid}/20_contamination.done"
  log "[DONE] contamination sample=${sid}"
}

run_orientation_model() {
  local sid="$1"

  mkdir -p "${F1R2_DIR}" "${STATUS_DIR}/${sid}" "${TMP_DIR}/${sid}"

  local in_f1r2="${F1R2_DIR}/${sid}.f1r2.tar.gz"
  local out_priors="${F1R2_DIR}/${sid}.read-orientation-model.tar.gz"

  [[ -r "${in_f1r2}" ]] || {
    echo "[ERROR] f1r2 tar not found for orientation model: ${in_f1r2}" >&2
    return 1
  }

  log "[RUN] orientation sample=${sid}"

  "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}" LearnReadOrientationModel \
    -I "${in_f1r2}" \
    -O "${out_priors}"

  touch "${STATUS_DIR}/${sid}/30_orientation.done"
  log "[DONE] orientation sample=${sid}"
}

run_filter_mutect_calls() {
  local sid="$1"

  mkdir -p "${FILTERED_DIR}" "${STATUS_DIR}/${sid}" "${TMP_DIR}/${sid}"

  local in_vcf="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz"
  local in_stats="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz.stats"
  local out_vcf="${FILTERED_DIR}/${sid}.filtered.vcf.gz"

  [[ -r "${in_vcf}" ]] || { echo "[ERROR] unfiltered vcf not found: ${in_vcf}" >&2; return 1; }
  [[ -r "${in_stats}" ]] || { echo "[ERROR] mutect2 stats not found: ${in_stats}" >&2; return 1; }

  log "[RUN] filter sample=${sid}"

  local cmd=(
    "${GATK_BIN}" --java-options "-Xmx12G -Djava.io.tmpdir=${TMP_DIR}/${sid}"
    FilterMutectCalls
    -R "${REFERENCE}"
    -V "${in_vcf}"
    --stats "${in_stats}"
    -O "${out_vcf}"
  )

  if [[ "${ENABLE_CONTAMINATION}" == "1" && -r "${CONTAM_DIR}/${sid}.contamination.table" ]]; then
    cmd+=(--contamination-table "${CONTAM_DIR}/${sid}.contamination.table")
  fi

  if [[ "${ENABLE_ORIENTATION}" == "1" && -r "${F1R2_DIR}/${sid}.read-orientation-model.tar.gz" ]]; then
    cmd+=(--ob-priors "${F1R2_DIR}/${sid}.read-orientation-model.tar.gz")
  fi

  "${cmd[@]}"

  touch "${STATUS_DIR}/${sid}/40_filter.done"
  log "[DONE] filter sample=${sid}"
}

run_annotation_placeholder() {
  local sid="$1"

  mkdir -p "${VCF_DIR}" "${ANNOVAR_DIR}" "${STATUS_DIR}/${sid}"

  local filtered_vcf="${FILTERED_DIR}/${sid}.filtered.vcf.gz"
  local anno_flag="${ANNOVAR_DIR}/${sid}.annotation.todo.txt"

  [[ -r "${filtered_vcf}" ]] || { echo "[ERROR] filtered vcf not found: ${filtered_vcf}" >&2; return 1; }

  # 先做轻量接口：提供稳定落盘点，后续再接入详细注释流程
  ln -sf "${filtered_vcf}" "${VCF_DIR}/${sid}.filtered.vcf.gz"
  {
    echo "sample_id=${sid}"
    echo "input_vcf=${filtered_vcf}"
    echo "status=annotation_placeholder"
    echo "message=后续可在此基础上接入 annovar/vcf2maf/自定义分析"
  } > "${anno_flag}"

  touch "${STATUS_DIR}/${sid}/50_annotation.done"
  log "[DONE] annotation placeholder sample=${sid}"
}

run_phase2_somatic_pipeline() {
  local sid="$1"
  local tumor_bam="$2"
  local normal_bam="$3"

  mkdir -p "${STATUS_DIR}/${sid}"

  # 1) mutect2
  if _should_run_by_end_stage mutect2; then
    run_mutect2 "${sid}" "${tumor_bam}" "${normal_bam}"
  fi

  # 2) contamination（可选）
  if _should_run_contamination; then
    run_contamination "${sid}" "${tumor_bam}" "${normal_bam}"
  else
    log "[SKIP] contamination disabled or beyond end-stage"
  fi

  # 3) orientation（可选）
  if _should_run_orientation; then
    run_orientation_model "${sid}"
  else
    log "[SKIP] orientation disabled or beyond end-stage"
  fi

  # 4) filter
  if _should_run_by_end_stage filter; then
    run_filter_mutect_calls "${sid}"
  fi

  # 5) annotation（可选占位）
  if _should_run_annotation; then
    run_annotation_placeholder "${sid}"
  else
    log "[SKIP] annotation disabled or beyond end-stage"
  fi

  touch "${STATUS_DIR}/${sid}/phase2.done"
  log "[DONE] phase2 somatic completed for sample=${sid}, end_stage=${END_STAGE}"
}
