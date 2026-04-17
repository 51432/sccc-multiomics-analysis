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

_ensure_vcf_tbi() {
  local vcf="$1"
  local tbi="${vcf}.tbi"

  [[ -r "${vcf}" ]] || {
    echo "[ERROR] vcf not found for indexing: ${vcf}" >&2
    return 1
  }

  if [[ -r "${tbi}" ]]; then
    return 0
  fi

  log "[RUN] index vcf=${vcf}"
  "${GATK_BIN}" --java-options "-Xmx4G -Djava.io.tmpdir=${TMP_DIR}" IndexFeatureFile \
    -I "${vcf}" \
    -O "${tbi}"

  [[ -r "${tbi}" ]] || {
    echo "[ERROR] failed to create vcf index: ${tbi}" >&2
    return 1
  }
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
  local f1r2_manifest="${F1R2_DIR}/${sid}.f1r2.inputs.list"

  local scatter_count="${MUTECT2_SCATTER_COUNT:-1}"
  local scatter_parallel="${MUTECT2_SCATTER_PARALLEL:-4}"
  if ! [[ "${scatter_count}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] MUTECT2_SCATTER_COUNT must be positive integer, got=${scatter_count}" >&2
    return 1
  fi
  if ! [[ "${scatter_parallel}" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] MUTECT2_SCATTER_PARALLEL must be positive integer, got=${scatter_parallel}" >&2
    return 1
  fi

  log "[RUN] mutect2 sample=${sid}"
  log "[PATH] tumor_bam=${tumor_bam} (SM=${tumor_sm})"
  log "[PATH] normal_bam=${normal_bam} (SM=${normal_sm})"
  log "[PATH] intervals=${INTERVALS}"
  log "[PATH] gnomad=${GNOMAD_RESOURCE}"
  if [[ "${scatter_parallel}" -gt "${scatter_count}" ]]; then
    scatter_parallel="${scatter_count}"
  fi
  log "[CONF] mutect2_scatter_count=${scatter_count}, mutect2_scatter_parallel=${scatter_parallel}"

  if [[ "${scatter_count}" -le 1 ]]; then
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
    printf '%s\n' "${out_f1r2}" > "${f1r2_manifest}"
  else
    # 单样本 task 内做 scatter/gather，不引入额外 sbatch/pbs
    local scatter_root="${TMP_DIR}/${sid}/mutect2_scatter"
    local scatter_intervals_dir="${scatter_root}/intervals"
    local shard_out_dir="${scatter_root}/shards"
    local gather_dir="${scatter_root}/gather"
    mkdir -p "${scatter_intervals_dir}" "${shard_out_dir}" "${gather_dir}"

    log "[RUN] split intervals sample=${sid}, scatter_count=${scatter_count}"
    "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}" SplitIntervals \
      -R "${REFERENCE}" \
      -L "${INTERVALS}" \
      --scatter-count "${scatter_count}" \
      -O "${scatter_intervals_dir}"

    local interval_files=()
    while IFS= read -r itv; do
      interval_files+=("${itv}")
    done < <(find "${scatter_intervals_dir}" -maxdepth 1 -type f -name "*.interval_list" | sort)
    [[ "${#interval_files[@]}" -gt 0 ]] || {
      echo "[ERROR] no scatter interval shards generated in ${scatter_intervals_dir}" >&2
      return 1
    }

    local shard_vcfs=()
    local shard_stats=()
    local shard_f1r2s=()
    local shard_idx=0
    local -a running_pids=()
    for itv in "${interval_files[@]}"; do
      shard_idx=$((shard_idx + 1))
      local shard_tag
      shard_tag="$(printf 'shard_%04d' "${shard_idx}")"
      local shard_vcf="${shard_out_dir}/${sid}.${shard_tag}.unfiltered.vcf.gz"
      local shard_stats_file="${shard_vcf}.stats"
      local shard_f1r2="${shard_out_dir}/${sid}.${shard_tag}.f1r2.tar.gz"
      local shard_tmp_dir="${scatter_root}/tmp/${shard_tag}"

      mkdir -p "${shard_tmp_dir}"

      log "[RUN] mutect2 ${shard_tag} sample=${sid} (bg)"
      (
        "${GATK_BIN}" --java-options "-Xmx24G -XX:+UseParallelGC -Djava.io.tmpdir=${shard_tmp_dir}" Mutect2 \
          -R "${REFERENCE}" \
          -L "${itv}" \
          -I "${tumor_bam}" -tumor "${tumor_sm}" \
          -I "${normal_bam}" -normal "${normal_sm}" \
          --germline-resource "${GNOMAD_RESOURCE}" \
          --panel-of-normals "${GATK_PON}" \
          --f1r2-tar-gz "${shard_f1r2}" \
          -O "${shard_vcf}"

        [[ -r "${shard_vcf}" ]] || { echo "[ERROR] shard vcf not found: ${shard_vcf}" >&2; exit 1; }
        [[ -r "${shard_stats_file}" ]] || { echo "[ERROR] shard stats not found: ${shard_stats_file}" >&2; exit 1; }
        [[ -r "${shard_f1r2}" ]] || { echo "[ERROR] shard f1r2 not found: ${shard_f1r2}" >&2; exit 1; }
      ) &
      running_pids+=("$!")

      shard_vcfs+=("${shard_vcf}")
      shard_stats+=("${shard_stats_file}")
      shard_f1r2s+=("${shard_f1r2}")

      # 并发上限 = scatter_parallel：每攒满一批就等待完成
      if [[ "${#running_pids[@]}" -ge "${scatter_parallel}" ]]; then
        for pid in "${running_pids[@]}"; do
          wait "${pid}" || {
            echo "[ERROR] mutect2 shard failed, sample=${sid}, pid=${pid}" >&2
            return 1
          }
        done
        running_pids=()
      fi
    done

    for pid in "${running_pids[@]}"; do
      wait "${pid}" || {
        echo "[ERROR] mutect2 shard failed, sample=${sid}, pid=${pid}" >&2
        return 1
      }
    done

    log "[RUN] gather mutect2 vcfs sample=${sid}"
    local gather_vcf_cmd=(
      "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}"
      GatherVcfs
      -O "${out_vcf}"
    )
    for vcf in "${shard_vcfs[@]}"; do
      gather_vcf_cmd+=(-I "${vcf}")
    done
    "${gather_vcf_cmd[@]}"

    log "[RUN] gather mutect2 stats sample=${sid}"
    local gather_stats_cmd=(
      "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}"
      MergeMutectStats
      -O "${out_stats}"
    )
    for st in "${shard_stats[@]}"; do
      gather_stats_cmd+=(--stats "${st}")
    done
    "${gather_stats_cmd[@]}"

    # F1R2 不直接拼 tar，改为聚合输入清单供 LearnReadOrientationModel 统一读取
    : > "${f1r2_manifest}"
    for f1r2 in "${shard_f1r2s[@]}"; do
      printf '%s\n' "${f1r2}" >> "${f1r2_manifest}"
    done
    # 保留一个稳定路径，便于向后兼容检查逻辑
    ln -sf "${shard_f1r2s[0]}" "${out_f1r2}"
  fi

  [[ -r "${out_stats}" ]] || {
    echo "[ERROR] mutect2 stats not found: ${out_stats}" >&2
    return 1
  }
  [[ -r "${out_vcf}" ]] || {
    echo "[ERROR] mutect2 vcf not found: ${out_vcf}" >&2
    return 1
  }
  _ensure_vcf_tbi "${out_vcf}"

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
  local in_f1r2_manifest="${F1R2_DIR}/${sid}.f1r2.inputs.list"
  local out_priors="${F1R2_DIR}/${sid}.read-orientation-model.tar.gz"

  log "[RUN] orientation sample=${sid}"
  local cmd=(
    "${GATK_BIN}" --java-options "-Xmx8G -Djava.io.tmpdir=${TMP_DIR}/${sid}"
    LearnReadOrientationModel
  )

  if [[ -r "${in_f1r2_manifest}" ]]; then
    local cnt=0
    while IFS= read -r f1r2; do
      [[ -n "${f1r2}" ]] || continue
      [[ -r "${f1r2}" ]] || {
        echo "[ERROR] f1r2 shard tar not found for orientation model: ${f1r2}" >&2
        return 1
      }
      cmd+=(-I "${f1r2}")
      cnt=$((cnt + 1))
    done < "${in_f1r2_manifest}"
    [[ "${cnt}" -gt 0 ]] || {
      echo "[ERROR] f1r2 manifest is empty: ${in_f1r2_manifest}" >&2
      return 1
    }
  else
    [[ -r "${in_f1r2}" ]] || {
      echo "[ERROR] f1r2 tar not found for orientation model: ${in_f1r2}" >&2
      return 1
    }
    cmd+=(-I "${in_f1r2}")
  fi

  cmd+=(-O "${out_priors}")
  "${cmd[@]}"

  touch "${STATUS_DIR}/${sid}/30_orientation.done"
  log "[DONE] orientation sample=${sid}"
}

run_filter_mutect_calls() {
  local sid="$1"

  mkdir -p "${FILTERED_DIR}" "${STATUS_DIR}/${sid}" "${TMP_DIR}/${sid}"

  local in_vcf="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz"
  local in_stats="${MUTECT2_DIR}/${sid}.unfiltered.vcf.gz.stats"
  local contamination_table="${CONTAM_DIR}/${sid}.contamination.table"
  local segmentation_table="${CONTAM_DIR}/${sid}.segments.table"
  local ob_priors="${F1R2_DIR}/${sid}.read-orientation-model.tar.gz"
  local out_vcf="${FILTERED_DIR}/${sid}.filtered.vcf.gz"
  local out_vcf_no_obpriors="${FILTERED_DIR}/${sid}.filtered.no-obpriors.vcf.gz"

  [[ -r "${in_vcf}" ]] || { echo "[ERROR] unfiltered vcf not found: ${in_vcf}" >&2; return 1; }
  [[ -r "${in_stats}" ]] || { echo "[ERROR] mutect2 stats not found: ${in_stats}" >&2; return 1; }
  [[ -r "${contamination_table}" ]] || { echo "[ERROR] contamination table not found: ${contamination_table}" >&2; return 1; }
  [[ -r "${segmentation_table}" ]] || { echo "[ERROR] tumor segmentation table not found: ${segmentation_table}" >&2; return 1; }
  [[ -r "${ob_priors}" ]] || { echo "[ERROR] read orientation priors not found: ${ob_priors}" >&2; return 1; }

  log "[RUN] filter(with ob-priors) sample=${sid}"

  local base_cmd=(
    "${GATK_BIN}" --java-options "-Xmx12G -Djava.io.tmpdir=${TMP_DIR}/${sid}"
    FilterMutectCalls
    -R "${REFERENCE}"
    -V "${in_vcf}"
    --stats "${in_stats}"
    --contamination-table "${contamination_table}"
    --tumor-segmentation "${segmentation_table}"
  )

  local cmd_with_ob=("${base_cmd[@]}")
  cmd_with_ob+=(
    --ob-priors "${ob_priors}"
    -O "${out_vcf}"
  )

  "${cmd_with_ob[@]}"
  _ensure_vcf_tbi "${out_vcf}"

  log "[RUN] filter(no-obpriors) sample=${sid}"
  local cmd_no_ob=("${base_cmd[@]}")
  cmd_no_ob+=(-O "${out_vcf_no_obpriors}")
  "${cmd_no_ob[@]}"
  _ensure_vcf_tbi "${out_vcf_no_obpriors}"

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
