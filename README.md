# FASTQ 预处理（SLURM Job Array 版本）

本仓库提供一套**纯 Bash** 的 FASTQ 预处理流程，面向 Linux + SLURM 集群：

1. 按 `sample_id` 聚合同一样本的多个 FASTQ 分片（R1/R2 分开 merge）
2. 对每个样本的 merged FASTQ 运行一次 `fastp`
3. 使用 SLURM job array 按样本并行提交任务，并支持并发上限控制

> 当前推荐入口脚本：
>
> - `01_submit_fastp_pipeline.sh`（提交器）
> - `02_run_fastp_pipeline_array.sh`（array worker）

---

## 输入格式

输入文件为 `samples.tsv`（tab 分隔，第一行为表头，必须严格为以下三列）：

```tsv
sample_id	input_R1	input_R2
sample1	/data/xxx/sample1_part1.R1.fastq.gz	/data/xxx/sample1_part1.R2.fastq.gz
sample1	/data/xxx/sample1_part2.R1.fastq.gz	/data/xxx/sample1_part2.R2.fastq.gz
sample2	/data/xxx/sample2_part1.R1.fastq.gz	/data/xxx/sample2_part1.R2.fastq.gz
sample2	/data/xxx/sample2_part2.R1.fastq.gz	/data/xxx/sample2_part2.R2.fastq.gz
```

---

## 输出目录结构

提交脚本会自动创建目录（已存在则跳过）：

```text
OUTDIR/
├── merged/
├── fastp/
├── reports_fastp/
│   └── <sample_id>/
├── logs/
└── meta/
```

- `merged/`：每个样本 merge 后的中间文件
  - `<sample_id>.R1.merged.fastq.gz`
  - `<sample_id>.R2.merged.fastq.gz`
- `fastp/`：每个样本的 fastp 输出
  - `<sample_id>.R1.fastp.fastq.gz`
  - `<sample_id>.R2.fastp.fastq.gz`
- `reports_fastp/<sample_id>/`：fastp 的 HTML/JSON 报告
- `logs/`：SLURM 标准输出与错误日志
- `meta/`：提交阶段生成的 `sample_ids.txt`

---

## 脚本说明

### 1) `01_submit_fastp_pipeline.sh`

负责：参数解析、读取 `samples.tsv`、生成去重后的 `sample_id` 列表、提交 SLURM array。

主要参数：

- `-i, --input`：输入 TSV（必填）
- `-o, --outdir`：输出目录（必填）
- `-p, --partition`：SLURM 分区，默认 `cpu`
- `-t, --threads`：每个样本 fastp 线程数，默认 `4`
- `-m, --mem`：每个 array task 内存，默认 `16G`
- `--max-parallel`：样本最大并发数，默认 `2`
- `--force`：强制覆盖（由 worker 执行清理后重跑）
- `--job-name`：SLURM 任务名
- `--worker-script`：自定义 worker 路径
- `-h, --help`：显示帮助

提交时会使用：

```bash
--array=0-(n-1)%MAX_PARALLEL
```

实现“按样本并发 + 并发上限”。

### 2) `02_run_fastp_pipeline_array.sh`

由 `SLURM_ARRAY_TASK_ID` 决定当前样本，执行以下逻辑：

1. 从 `sample_ids.txt` 取当前 `sample_id`
2. 在 `samples.tsv` 中抓取该样本全部 R1/R2 分片
3. 检查 R1/R2 数量一致
4. 检查每个输入 FASTQ 文件存在且非空
5. merge 分片（直接 `cat` 多个 `.fastq.gz`）
6. 运行 `fastp` 生成 clean reads 与报告
7. 已有非空输出时自动跳过；`FORCE=1` 时先删除旧结果再重跑

---

## 示例运行

```bash
bash 01_submit_fastp_pipeline.sh \
  -i samples.tsv \
  -o /data/project/run1 \
  -p cpu2 \
  -t 4 \
  -m 32G \
  --max-parallel 3 \
  --force
```

---

## 运行逻辑（简要）

- 提交阶段：
  - 校验 TSV 表头
  - 生成去重且顺序稳定的 `sample_ids.txt`
  - 计算 array 区间并提交 job array
- worker 阶段（每个样本一个 task）：
  - 提取同一样本全部分片并校验
  - 先 merge，再 fastp
  - 可断点续跑；`--force` 可覆盖旧结果

---

## 依赖

- `bash`
- `awk`, `sed`, `cat`, `mkdir`, `wc`
- `sbatch`（SLURM）
- `fastp`（worker 运行时会检查 PATH）
