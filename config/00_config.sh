# ========= 基础 =========
export PIPELINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKDIR="${WORKDIR:-$(pwd)}"

export MODE="${MODE:-wes}"                 # wes|wgs
export PIPELINE_PHASE="${PIPELINE_PHASE:-phase1}"   # phase1|phase2
export SAMPLES_TSV="${SAMPLES_TSV:-samples.tsv}"
export SAMPLE_PAIRS_TSV="${SAMPLE_PAIRS_TSV:-sample_pairs.tsv}"

# 兼容前半段
export ENABLE_CHECK_PAIRS="${ENABLE_CHECK_PAIRS:-1}"   # 1/0

# phase2 可选阶段控制
export END_STAGE="${END_STAGE:-filter}"                 # mutect2|contamination|orientation|filter|annotation
export ENABLE_CONTAMINATION="${ENABLE_CONTAMINATION:-1}" # 1/0
export ENABLE_ORIENTATION="${ENABLE_ORIENTATION:-1}"     # 1/0
export ENABLE_ANNOTATION="${ENABLE_ANNOTATION:-0}"       # 1/0
export ENABLE_PON="${ENABLE_PON:-1}"                     # 1/0

export MAX_PARALLEL="${MAX_PARALLEL:-8}"

#============输出路径设置=======================
export OUT_ROOT="/data/person/wup/public/liusy_files/sccc/preprocessed_bam/${MODE}"

export FASTP_DIR="${OUT_ROOT}/fastp"
export MERGED_FASTQ_DIR="${OUT_ROOT}/merged_fastq"
export ALIGNED_DIR="${OUT_ROOT}/sorted.bam"
export PREPROC_DIR="${OUT_ROOT}/markdup_bam"
export BQSR_DIR="${OUT_ROOT}/bqsr"


#================log路径路径路径==============
export LOG_DIR="${LOG_DIR:-${WORKDIR}/logs/slurm}"
export TMP_DIR="${TMP_DIR:-${WORKDIR}/tmp}"
export STATUS_DIR="${STATUS_DIR:-${WORKDIR}/status}"


#=================结果输出位置========================
export PROJECT_OUT_ROOT="/data/person/wup/public/liusy_files/sccc/output/${MODE}_somatic"
# phase2（沿用之前命名）
export MUTECT2_DIR="${PROJECT_OUT_ROOT}/mutect2"
export CONTAM_DIR="${PROJECT_OUT_ROOT}/contamination"
export F1R2_DIR="${PROJECT_OUT_ROOT}/f1r2"
export FILTERED_DIR="${PROJECT_OUT_ROOT}/filtered"

# 后续注释/分析
export VCF_DIR="${PROJECT_OUT_ROOT}/vcf"
export ANNOVAR_DIR="${PROJECT_OUT_ROOT}/annovar"
export ANALYSES_DIR="${PROJECT_OUT_ROOT}/analyses"
export EXPORT_DIR="${PROJECT_OUT_ROOT}/export"


for dir in \
  "${OUT_ROOT}" "${FASTP_DIR}" "${MERGED_FASTQ_DIR}" "${ALIGNED_DIR}" "${PREPROC_DIR}" "${BQSR_DIR}" \
  "${LOG_DIR}" "${STATUS_DIR}" \
  "${MUTECT2_DIR}" "${CONTAM_DIR}" "${F1R2_DIR}" "${FILTERED_DIR}" \
  "${VCF_DIR}" "${ANNOVAR_DIR}" "${ANALYSES_DIR}" "${EXPORT_DIR}"; do
    if [[ ! -d "${dir}" ]]; then
        mkdir -p "${dir}"
        echo "[INFO] created directory: ${dir}"
    else
        echo "[INFO] directory exists: ${dir}"
    fi
done

# ========= 参考基因组（真实路径） =========
export HG38_ROOT="/data/person/wup/public/liusy_files/reference_genomes/hg38"
export HG38_REF_DIR="${HG38_ROOT}/reference"
export HG38_RES_DIR="${HG38_ROOT}/resources"
export HG38_INT_DIR="${HG38_ROOT}/intervals/AgilentSureSelectV5"

export REFERENCE="${HG38_REF_DIR}/Homo_sapiens_assembly38.fasta"
export REFERENCE_DICT="${HG38_REF_DIR}/Homo_sapiens_assembly38.dict"

export KNOWNSITES_SNPS="${HG38_RES_DIR}/1000G_phase1.snps.high_confidence.hg38.vcf.gz"
export KNOWNSITES_INDELS="${HG38_RES_DIR}/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"

# 第二阶段会用到，先放好
export GNOMAD_RESOURCE="${HG38_RES_DIR}/af-only-gnomad.hg38.vcf.gz"
export GATK_PON="${HG38_RES_DIR}/1000g_pon.hg38.vcf.gz"

# ========= interval（按你提供文件名） =========
# WES
export INTERVALS_WES="${INTERVALS_WES:-${HG38_INT_DIR}/hg38.interval_list}"
export INTERVALS_BED_WES="${INTERVALS_BED_WES:-${HG38_INT_DIR}/chr1_chr22_intervals.bed}"

# WGS
export INTERVALS_WGS="${INTERVALS_WGS:-${HG38_INT_DIR}/wgs_calling_regions.hg38.interval_list}"
# 你当前目录未见独立wgs bed，这里先复用 chr1_chr22_intervals.bed（阶段2再细化）
export INTERVALS_BED_WGS="${INTERVALS_BED_WGS:-${HG38_INT_DIR}/chr1_chr22_intervals.bed}"

case "${MODE}" in
  wes)
    export INTERVALS="${INTERVALS_WES}"
    export INTERVALS_BED="${INTERVALS_BED_WES}"
    ;;
  wgs)
    export INTERVALS="${INTERVALS_WGS}"
    export INTERVALS_BED="${INTERVALS_BED_WGS}"
    ;;
  *)
    echo "[ERROR] MODE must be wes|wgs, got=${MODE}" >&2
    exit 1
    ;;
esac

case "${PIPELINE_PHASE}" in
  phase1|phase2) ;;
  *)
    echo "[ERROR] PIPELINE_PHASE must be phase1|phase2, got=${PIPELINE_PHASE}" >&2
    exit 1
    ;;
esac

case "${END_STAGE}" in
  mutect2|contamination|orientation|filter|annotation) ;;
  *)
    echo "[ERROR] END_STAGE must be mutect2|contamination|orientation|filter|annotation, got=${END_STAGE}" >&2
    exit 1
    ;;
esac

# ========= 软件路径（真实路径优先） =========
export SOFTWARE_ROOT="/data/person/wup/liusy/software"

# 强制用 bwa-mem2 mem
export BWA_MEM2_BIN="${BWA_MEM2_BIN:-${SOFTWARE_ROOT}/bwa-mem2-2.2.1_x64-linux/bwa-mem2}"

# 其他工具
export GATK_BIN="${GATK_BIN:-${SOFTWARE_ROOT}/gatk-4.4.0.0/gatk}"
export SAMTOOLS_BIN="${SAMTOOLS_BIN:-${SOFTWARE_ROOT}/samtools-1.20/samtools}"
# sambamba如果不在固定目录，就走PATH
export SAMBAMBA_BIN="${SAMBAMBA_BIN:-/data/person/wup/public/software/miniconda3/envs/gatk/bin/sambamba}"
export FASTP_BIN="${FASTP_BIN:-/data/person/wup/public/software/miniconda3/envs/fastp/bin/fastp}"

# ========= 启动校验 =========
_required=(
  "${REFERENCE}"
  "${REFERENCE_DICT}"
  "${KNOWNSITES_SNPS}"
  "${KNOWNSITES_INDELS}"
  "${INTERVALS}"
  "${GATK_BIN}"
  "${SAMTOOLS_BIN}"
)

# phase1 额外依赖
if [[ "${PIPELINE_PHASE}" == "phase1" ]]; then
  _required+=("${BWA_MEM2_BIN}")
fi

# phase2 额外依赖
if [[ "${PIPELINE_PHASE}" == "phase2" ]]; then
  _required+=("${GNOMAD_RESOURCE}")
fi

for f in "${_required[@]}"; do
  [[ -r "${f}" ]] || { echo "[ERROR] required file/tool not readable: ${f}" >&2; exit 1; }
done

command -v "${SAMBAMBA_BIN}" >/dev/null 2>&1 || {
  echo "[ERROR] sambamba not found in PATH. 请设置 SAMBAMBA_BIN=/path/to/sambamba" >&2
  exit 1
}

log() { echo "[$(date '+%F %T')] $*"; }
export -f log
