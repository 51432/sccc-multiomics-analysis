# FASTQ 质控与合并 Pipeline

本目录用于 **paired-end FASTQ 批量质控（fastp）与按样本合并**。

核心脚本：`run_pipeline.sh`  
示例清单：`samples.tsv`

---

## 功能概述

该 pipeline 适用于以下场景：

- 同一个 `sample_id` 在 TSV 中出现多行（表示多个分片）。
- 先按 `sample_id` 合并所有分片原始 FASTQ，再执行一次样本级 `fastp` 质控。
- 合并后的原始文件保存到 `merged/`，最终 fastp 结果保存到 `fastq/`。
- 质控报告（html/json）按样本保存到 `reports_fastq/<sample_id>/`。
- 日志目录通过 `-l` 单独指定，不放在输出目录中。

---

## 输入格式

输入为一个 TSV 文件，且表头固定为：

```tsv
sample_id	input_R1	input_R2
```

示例（见 `samples.tsv`）：

```tsv
sample1	/data/xxx/sample1_part1.R1.fastq.gz	/data/xxx/sample1_part1.R2.fastq.gz
sample1	/data/xxx/sample1_part2.R1.fastq.gz	/data/xxx/sample1_part2.R2.fastq.gz
sample2	/data/xxx/sample2_part1.R1.fastq.gz	/data/xxx/sample2_part1.R2.fastq.gz
sample2	/data/xxx/sample2_part2.R1.fastq.gz	/data/xxx/sample2_part2.R2.fastq.gz
```

> `partN` 编号由脚本按 TSV 读取顺序自动生成，并在同一 `sample_id` 内递增。

---

## 输出目录结构

执行后输出目录结构如下：

```text
/path/to/output/
├── merged/
├── fastq/
└── reports_fastq/
```

说明：

- `merged/`：每个样本的合并结果
  - `sample_id.R1.merged.fastq.gz`（先合并得到的原始 R1）
  - `sample_id.R2.merged.fastq.gz`（先合并得到的原始 R2）
- `fastq/`：每个样本最终 fastp 结果
  - `sample_id.R1.fastp.gz`
  - `sample_id.R2.fastp.gz`
- `reports_fastq/`：按样本分目录保存 fastp 报告
  - `reports_fastq/sample1/*.html, *.json`

---

## 参数说明

```bash
./run_pipeline.sh \
  -i samples.tsv \
  -o /path/to/output \
  -l /path/to/logs \
  -t 4 \
  [--dry-run] [--force] [--skip-done]
```

- `-i`：输入 TSV
- `-o`：输出根目录
- `-l`：日志目录（每个样本一个日志文件）
- `-t`：线程数，默认 `4`
- `--dry-run`：只打印命令，不执行
- `--force`：强制重建 merged 与 fastp 结果
- `--skip-done`：若某样本最终 `sample_id.R1.fastp.gz` 与 `sample_id.R2.fastp.gz` 已存在则跳过

---

## 执行流程（简要）

1. 参数解析与基础检查（`fastp`、输入 TSV、线程数）。
2. 校验 TSV 表头与每行三列格式。
3. 校验每行输入 FASTQ 文件是否存在。
4. 按 `sample_id` 与 TSV 顺序先合并同一样本的原始分片 FASTQ。
5. 若 `merged/` 已有样本合并文件则跳过合并；否则先合并。
6. 对样本级 R1/R2 执行一次 `fastp`（若 `fastq/` 已有结果则默认跳过）。
7. 输出完成信息，日志写入 `-l` 指定目录。

---

## 常见说明

- 若样本仅有一对 FASTQ，也会先合并（等价于复制拼接）再进行 fastp。
- 未开启 `--force` 时，不会覆盖已有 merged/fastp 结果，而是自动跳过对应步骤。
- 每个样本会先生成 `merged/*.merged.fastq.gz`，再生成 `fastq/*.fastp.gz`。
- pipeline 中断后可直接重跑：已有 merged 会跳过合并，已有 fastp 会跳过质控，从断点继续。

---

## 在 SLURM/sbatch 中提交运行

如果你在集群中通过 `sbatch` 提交任务，可以新建提交脚本（例如 `submit_pipeline.sbatch`）：

```bash
#!/bin/bash
#SBATCH --job-name=survirus_array
#SBATCH --partition=cpu1
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --output=logs/array_%A_%a.out
#SBATCH --error=logs/array_%A_%a.err

set -euo pipefail

# 根据你的环境修改以下路径
source /data/person/wup/public/software/miniconda3/bin/activate fastp

TSV="/data/person/wup/liusy/wgs/scripts/paired-end-fastq/wes_pairs.tsv"
OUT="/data/person/wup/public/liusy_files/sccc/preprocessed_bam/wes/fastq"
LOG_DIR="/data/person/wup/liusy/wgs/scripts/paired-end-fastq/logs"
THREADS=4

/data/person/wup/liusy/wgs/scripts/paired-end-fastq/run_pipeline.sh -i "$TSV" -o "$OUT" -l "$LOG_DIR" -t "$THREADS" --skip-done
```

> 说明：
> - 上面示例中的 `#SBATCH` 参数可按集群资源策略调整。
> - `--cpus-per-task` 建议与 `-t` 线程数保持一致。
> - `#SBATCH --output/--error` 是 SLURM 作业日志，`-l` 是 pipeline 的样本日志目录。

---

## 从文件夹导出 FASTQ 路径并手动整理

在整理样本前，通常可以先把目录中所有 `fastq.gz` 文件路径导出出来，便于后续下载和人工配对。

### 1）仅列出 `.fastq.gz` 文件路径

```bash
find /data/person/wup/public/liusy_files/sccc/raw_data/wes -type f -name "*.fastq.gz" | while read -r f; do realpath "$f"; done | awk -F/ '{print $NF "\t" $0}' | sort -V -k1,1 | cut -f2-
```

### 2）导出两列 tsv（奇数和偶数区分便于 Excel 整理双端配对）

```bash
find /data/person/wup/public/liusy_files/sccc/raw_data/wes -type f -name "*.fastq.gz" | while read -r f; do realpath "$f"; done | awk -F/ '{print $NF "\t" $0}' | sort -V -k1,1 | cut -f2- | awk 'BEGIN{OFS="\t"; print "input_R1","input_R2"} NR%2==1{r1=$0; next} {print r1,$0}' > /data/person/wup/liusy/wgs/wes_pairs.tsv
```

导出后可在 Excel/WPS 中按文件名规则筛选并手动整理成 pipeline 所需的 TSV 三列：

- `sample_id`
- `input_R1`
- `input_R2`
