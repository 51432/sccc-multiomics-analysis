# SCCC WGS/WES Tumor-Normal Somatic Pipeline（Slurm 版）

本仓库保持 **一个 Slurm array task 对应一个样本单元** 的设计，并分为两段：

- **phase1**：`R1/R2.fastp.gz`（或 fastq.gz）→ 比对/去重/BQSR
- **phase2**：`tumor_bam + normal_bam`（BQSR BAM）→ Mutect2/污染估计/方向性模型/过滤/注释占位

> 当前重点：phase2 第一阶段已实现到 `filtered.vcf.gz`，annotation 先提供轻量接口占位。

---

## 1. 目录与脚本

- `config/00_config.sh`：统一配置（mode、路径、阶段开关、工具路径、参考资源）
- `01_submit_slurm_array.sh`：统一提交入口（phase1/phase2）
- `run_sample_array.sbatch`：array 模板
- `02_run_sample_task.sh`：单个 task 执行入口（按 phase 分流）
- `lib/steps_phase1_preprocess.sh`：前半段（已跑通，保留）
- `lib/steps_somatic.sh`：后半段（新增）
- `lib/validate_samples_tsv.sh`：样本表校验（含 `sample_pairs.tsv` 严格校验）

---

## 2. phase2 输入格式（固定）

文件名建议：`sample_pairs.tsv`。

表头必须严格为（TAB 分隔）：

```tsv
sample_id	tumor_bam	normal_bam
```

示例：

```tsv
SDE014	/data/person/wup/public/liusy_files/sccc/preprocessed_bam/wes/bqsr/TSDE014.bqsr.bam	/data/person/wup/public/liusy_files/sccc/preprocessed_bam/wes/bqsr/NSDE014.bqsr.bam
```

从 BQSR BAM 自动生成 `pairs.tsv` 示例脚本：

```bash
#!/usr/bin/env bash

bam_dir="/data/person/wup/public/liusy_files/sccc/preprocessed_bam/wes/bqsr"
out_tsv="pair.tsv"

echo -e "sample_id\ttumor_bam\tnormal_bam" > "${out_tsv}"

find "${bam_dir}" -maxdepth 1 -type f -name "*.bqsr.bam" | sort | while read -r bam; do
    base=$(basename "${bam}")

    # 只处理 tumor 文件，避免重复写入
    # 例如 TSDE014.bqsr.bam -> sample_id = SDE014
    if [[ "${base}" =~ ^T(.+)\.bqsr\.bam$ ]]; then
        sample_id="${BASH_REMATCH[1]}"
        tumor_bam="${bam}"
        normal_bam="${bam_dir}/N${sample_id}.bqsr.bam"

        if [[ -f "${normal_bam}" ]]; then
            echo -e "${sample_id}\t${tumor_bam}\t${normal_bam}" >> "${out_tsv}"
        else
            echo "[WARN] normal bam not found for sample_id=${sample_id}: ${normal_bam}" >&2
        fi
    fi
done

echo "Done. Output written to ${out_tsv}"
```

已实现严格校验：

1. 表头严格匹配
2. 必须 TAB 分隔（不接受 CSV/空格）
3. 固定 3 列
4. `sample_id` 唯一
5. `tumor_bam` / `normal_bam` 可读
6. 二者不可相同
7. 错误格式统一为：
   ```text
   [ERROR] line=<行号> sample_id=<ID> message=<错误原因>
   ```

---

## 3. phase2 主链（已实现）

默认主链：

1. Mutect2
2. GetPileupSummaries（tumor/normal）
3. CalculateContamination
4. LearnReadOrientationModel（基于 F1R2）
5. FilterMutectCalls
6. Annotation（占位接口）

说明：

- **不实现** PoN 构建、不实现 HaplotypeCaller Germline、不恢复 PBS/qsub。
- `PoN`（`${GATK_PON}`）默认启用并作为 Mutect2 固定输入。
- `--germline-resource ${GNOMAD_RESOURCE}` 默认保留。
- `FilterMutectCalls` 会输出两个版本：
  - `${sample_id}.filtered.vcf.gz`（默认包含 `--contamination-table`、`--tumor-segmentation`、`--ob-priors`）
  - `${sample_id}.filtered.no-obpriors.vcf.gz`（不带 `--ob-priors`）

---

## 4. 阶段可选控制

支持 `--end-stage`：

- `mutect2`
- `contamination`
- `orientation`
- `filter`
- `annotation`

并支持开关：

- `--enable-contamination 1|0`
- `--enable-orientation 1|0`
- `--enable-annotation 1|0`

默认值见 `config/00_config.sh`。

---

## 5. 提交命令示例

## 5.1 phase1（保留原逻辑）

```bash
bash 01_submit_slurm_array.sh --pipeline phase1 --samples input/samples.tsv --mode wes --max-parallel 2
```

## 5.2 phase2：从 BQSR BAM 到 filtered VCF

```bash
bash 01_submit_slurm_array.sh \
  --pipeline phase2 \
  --pairs input/sample_pairs.tsv \
  --mode wes \
  --max-parallel 2 \
  --enable-contamination 1 \
  --enable-orientation 1 \
  --enable-annotation 0
```

## 5.3 只跑 Mutect2

```bash
bash 01_submit_slurm_array.sh \
  --pipeline phase2 \
  --pairs input/sample_pairs.tsv \
  --mode wes \
  --end-stage mutect2
```

---

## 6. phase2 输出路径（已复用 config）

- `MUTECT2_DIR`：`*.unfiltered.vcf.gz`
- `CONTAM_DIR`：pileups / contamination / segments
- `F1R2_DIR`：`*.f1r2.tar.gz` / `*.read-orientation-model.tar.gz`
- `FILTERED_DIR`：`*.filtered.vcf.gz`
- `VCF_DIR`、`ANNOVAR_DIR`：annotation 占位输出

所有目录都采用“先判断是否存在，不存在再创建”的方式。

---

## 7. 说明

- 保留前半段结构，不推翻已跑通流程。
- 后半段采用最小可维护扩展：新增函数集中在 `lib/steps_somatic.sh`。
- 后续若需要深化 annotation/analysis，可在当前接口基础上继续扩展。

---

## 8. 服务器下载与解压

在服务器上可直接执行以下命令下载并解压当前分支代码包：

```bash
wget "https://github.com/51432/sccc-multiomics-analysis/archive/refs/heads/codex/update-run_filter_mutect_calls-output-logic.zip"
unzip update-run_filter_mutect_calls-output-logic.zip -d ./
```
