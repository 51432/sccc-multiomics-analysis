# FASTQ 质控与合并 Pipeline

本目录用于 **paired-end FASTQ 批量质控（fastp）与按样本合并**。

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

