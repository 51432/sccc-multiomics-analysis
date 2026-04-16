# SCCC WGS/WES 肿瘤-对照（Tumor-Normal）体细胞突变分析 Pipeline（Phase 1）

这个仓库用于 **从 fastp 质控后的双端 FASTQ（`R1.fastp.gz` / `R2.fastp.gz`）开始**，批量完成以下预处理步骤：

1. 配对输入检查（当前为 passthrough）
2. `bwa-mem2` 比对 + `sambamba sort`
3. `sambamba markdup`
4. `GATK BaseRecalibrator + ApplyBQSR`

最终产物是每个样本的 `*.bqsr.bam`，可直接进入后续 somatic calling（如 Mutect2）流程。

---

## 1. 仓库脚本结构

- `01_submit_slurm_array.sh`：读取样本表并提交 SLURM array 任务。
- `run_sample_array.sbatch`：SLURM 任务模板。
- `02_run_sample_task.sh`：单个 array task 的样本执行入口。
- `lib/validate_samples_tsv.sh`：样本表校验（表头、列数、重复 sample_id、文件可读性）。
- `lib/steps_somatic_phase1.sh`：phase1 的四个核心步骤。
- `config/00_config.sh`：统一配置（mode、路径、参考基因组、工具路径、输出目录等）。

---

## 2. 输入要求

## 2.1 样本表格式

样本表必须是 TSV，且表头固定为：

```tsv
sample_id	input_R1	input_R2
```

示例：

```tsv
sampleA_T	/path/to/sampleA_T.R1.fastp.gz	/path/to/sampleA_T.R2.fastp.gz
sampleA_N	/path/to/sampleA_N.R1.fastp.gz	/path/to/sampleA_N.R2.fastp.gz
sampleB_T	/path/to/sampleB_T.R1.fastp.gz	/path/to/sampleB_T.R2.fastp.gz
sampleB_N	/path/to/sampleB_N.R1.fastp.gz	/path/to/sampleB_N.R2.fastp.gz
```

> 说明：
> - 本阶段按“单样本”执行，不在 phase1 内显式做 T/N 成对计算。
> - 建议使用一致命名规范（例如 `_T`、`_N` 后缀）为后续 somatic phase2 做配对映射。

## 2.2 FASTQ 要求

- 输入应为已完成 fastp 的双端压缩 FASTQ：`*.fastp.gz`。
- `input_R1` 与 `input_R2` 必须可读。

---

## 3. 运行方式（与你当前用法一致）

你当前成功运行的命令是：

```bash
bash 01_submit_slurm_array.sh --samples input/samples.tsv --mode wes --max-parallel 2
```

参数说明：

- `--samples`：样本 TSV 路径。
- `--mode`：`wes` 或 `wgs`，用于切换 interval 与输出路径。
- `--max-parallel`：SLURM array 同时并发的最大样本数（`%N`）。
- `--check-pairs`：`1|0`，默认 `1`（目前为 passthrough，不做额外拆分）。

可用帮助：

```bash
bash 01_submit_slurm_array.sh --help
```

---

## 4. 执行逻辑

## 4.1 提交流程

`01_submit_slurm_array.sh` 会：

1. 加载 `config/00_config.sh`。
2. 调用 `validate_samples_tsv` 校验样本表。
3. 根据样本数计算 `--array=0-(n-1)%max_parallel`。
4. 通过 `sbatch run_sample_array.sbatch` 提交任务。

## 4.2 每个样本的处理步骤

`02_run_sample_task.sh` 根据 `SLURM_ARRAY_TASK_ID` 取样本行后，顺序运行：

1. `run_check_pairs`
2. `run_align_sort`
3. `run_markduplicates`
4. `run_bqsr`

并在 `status/<sample_id>/` 下写入阶段完成标记：

- `01_check_pairs.done`
- `02_align_sort.done`
- `03_markdup.done`
- `04_bqsr.done`
- `phase1.done`

---

## 5. 输出目录

输出根目录由 `config/00_config.sh` 中的 `OUT_ROOT` 控制：

```bash
OUT_ROOT=/data/person/wup/public/liusy_files/sccc/preprocessed_bam/${MODE}
```

主要输出：

- `sorted.bam/<sample>.sorted.bam`：比对并排序后的 BAM
- `markdup_bam/<sample>.markdup.bam`：去重复后的 BAM
- `bqsr/<sample>.bqsr.bam`：BQSR 后 BAM（phase1 主产物）

日志与状态：

- `logs/slurm/`：SLURM 标准输出与标准错误
- `logs/slurm/sample/<sample>.pipeline.log`：样本级流程日志
- `status/<sample>/`：步骤完成标记

---

## 6. 关键配置文件说明（`config/00_config.sh`）

你通常需要按服务器环境确认或修改以下内容：

- `MODE`：`wes` / `wgs`
- `SAMPLES_TSV`：样本表默认路径
- `MAX_PARALLEL`：默认并发数
- `OUT_ROOT` / `PROJECT_OUT_ROOT`：输出目录
- `REFERENCE` / `REFERENCE_DICT`：参考基因组
- `KNOWNSITES_SNPS` / `KNOWNSITES_INDELS`：BQSR 资源
- `INTERVALS_WES` / `INTERVALS_WGS`：不同模式 interval
- `BWA_MEM2_BIN` / `GATK_BIN` / `SAMTOOLS_BIN` / `SAMBAMBA_BIN`：工具可执行文件路径

脚本在启动时会校验必要文件/工具是否可读，不满足会直接报错退出。

---

## 7. 常见问题

## 7.1 为什么我看到 fastp 目录变量但没有在 phase1 里重新跑 fastp？

本仓库当前 phase1 假设输入已经是 fastp 产物，流程从比对开始。

## 7.2 肿瘤-对照配对在哪里体现？

phase1 是“单样本预处理”。肿瘤-对照配对通常在后续 somatic calling（phase2，例如 Mutect2）阶段进行。

## 7.3 如何续跑？

- 可直接重提 array。
- 已完成样本可结合 `status/` 和输出文件自行筛选后重跑或跳过。

---

## 8. 最小复现命令

WES：

```bash
bash 01_submit_slurm_array.sh --samples input/samples.tsv --mode wes --max-parallel 2
```

WGS：

```bash
bash 01_submit_slurm_array.sh --samples input/samples.tsv --mode wgs --max-parallel 2
```

---

## 9. 版本定位

本 README 对应当前仓库中 **phase1（fastp 后 -> BQSR）** 的真实脚本行为。
如果后续补充 phase2（Mutect2、污染评估、过滤、注释），建议在本 README 追加新章节，而不是复制平行 scaffold。
