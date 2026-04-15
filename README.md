# FASTQ 质控与合并 Pipeline

本目录用于 **paired-end WGE/WES FASTQ 批量质控（fastp）与按样本合并**。

核心脚本：`run_pipeline.sh`  
示例清单：`samples.tsv`

---

## 功能概述

该 pipeline 适用于以下场景：

- 同一个 `sample_id` 在 TSV 中出现多行（表示多个分片）。
- 每个分片先进行一次 `fastp` 质控。
- 所有分片质控结果统一平铺到 `fastp_intermediate/`。
- 按 `sample_id` 将分片结果合并到 `merged/`。
- 质控报告（html/json）按样本保存到 `reports/<sample_id>/`。
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
├── fastp_intermediate/
├── merged/
└── reports/
```

说明：

- `fastp_intermediate/`：平铺保存中间结果
  - `sample_id.partN.R1.fastp.gz`
  - `sample_id.partN.R2.fastp.gz`
- `merged/`：每个样本最终合并结果
  - `sample_id.R1.fastp.gz`
  - `sample_id.R2.fastp.gz`
- `reports/`：按样本分目录保存 fastp 报告
  - `reports/sample1/*.html, *.json`

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
- `--force`：若目标输出存在则覆盖
- `--skip-done`：若某样本 merged 结果已存在则跳过

---

## 执行流程（简要）

1. 参数解析与基础检查（`fastp`、输入 TSV、线程数）。
2. 校验 TSV 表头与每行三列格式。
3. 校验每行输入 FASTQ 文件是否存在。
4. 按 TSV 顺序对每个分片执行 `fastp`。
5. 按 `sample_id` 检查中间文件完整性并合并到 `merged/`。
6. 输出完成信息，日志写入 `-l` 指定目录。

---

## 常见说明

- 若样本仅有一对 FASTQ，仍会正常生成对应 merged 文件。
- 未开启 `--force` 时，若目标文件已存在会报错退出，避免误覆盖。
- 合并前会检查所有中间文件是否存在，缺失则立即报错。

---

## 在 SLURM/sbatch 中提交运行

如果你在集群中通过 `sbatch` 提交任务，可以新建提交脚本（例如 `submit_pipeline.sbatch`）：

```bash
#!/bin/bash
#SBATCH --job-name=survirus_array
#SBATCH --partition=cpu2
#SBATCH --cpus-per-task=1
#SBATCH --mem=12G
#SBATCH --array=0-91%8
#SBATCH --output=logs/array_%A_%a.out
#SBATCH --error=logs/array_%A_%a.err

set -euo pipefail

# 根据你的环境修改以下路径
TSV="/path/to/samples.tsv"
OUT="/path/to/output"
LOG_DIR="/path/to/pipeline_logs"
THREADS=1

./run_pipeline.sh -i "$TSV" -o "$OUT" -l "$LOG_DIR" -t "$THREADS"
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
find /path/to/your_folder -type f -name "*.fastq.gz"
```

### 2）导出仅 `file_path` 一列的 CSV

```bash
find /path/to/your_folder -type f -name "*.fastq.gz" | sort | awk 'BEGIN{print "file_path"} {gsub(/"/, "\"\"", $0); print "\"" $0 "\""}' > fastq_files.csv
```

### 3）导出三列 CSV（便于 Excel 整理双端配对）

```bash
find /path/to/your_folder -type f -name "*.fastq.gz" | sort | awk 'BEGIN{print "file_path,file_name,parent_dir"} {path=$0; n=split($0,a,"/"); file=a[n]; dir=$0; sub("/" file "$","",dir); gsub(/"/,"\"\"",path); gsub(/"/,"\"\"",file); gsub(/"/,"\"\"",dir); print "\"" path "\",\"" file "\",\"" dir "\""}' > fastq_files.csv
```

导出后可在 Excel/WPS 中按文件名规则筛选并手动整理成 pipeline 所需的 TSV 三列：

- `sample_id`
- `input_R1`
- `input_R2`
