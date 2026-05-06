# Figure 1：snRNA-seq/scRNA-seq 汇总为 bulk-like count data（不过滤基因）

本目录提供脚本，把每个样本的 10X 单细胞/单核表达矩阵按**所有细胞（all-cell）直接求和**，生成样本 × 基因的 pseudo-bulk count 矩阵。

> 关键点：
> - 不做任何基因过滤。
> - 不丢弃任何细胞/细胞核。
> - 输出为下游 bulk RNA 分析可直接使用的 count data。

---

## 1. 输入文件

在运行目录下准备 `tenx_manifest.tsv`（制表符分隔），至少包含：

- `sample_id`：样本名（会作为输出矩阵列名）
- `path`：10X 目录路径（目录内包含 `matrix.mtx.gz`、`features.tsv.gz` 或 `genes.tsv.gz`、`barcodes.tsv.gz`）

示例：

```tsv
sample_id	path
SCCC_01	/data/sccc/SCCC_01/filtered_feature_bc_matrix
SCCC_02	/data/sccc/SCCC_02/filtered_feature_bc_matrix
```

---

## 2. 运行方法

你反馈的环境里有 `R_HOME` 干扰，运行前先取消：

```bash
cd figure_1
unset R_HOME
Rscript make_allcell_pseudobulk_from_10x.R
```

说明：
- `make_allcell_pseudobulk_from_10x.R` 是入口脚本；
- 实际逻辑在 `make_allcell_pseudobulk_from_10x_no_filter.R`。

---

## 3. 输出结果

会生成目录 `pseudobulk_allcell_out/`，包含：

1. `allcell_pseudobulk_counts.tsv`
   - 第一列 `gene`
   - 后续列为各 `sample_id` 的 count
   - 数值为该基因在该样本全部细胞/核上的 UMI 求和

2. `allcell_pseudobulk_qc.tsv`
   - 每个样本的基础汇总信息（`n_cells`、`n_genes`、`total_UMI` 等）
   - 仅记录，不做过滤

---

## 4. 依赖

仅依赖 `Matrix` 包（不再依赖 Seurat，避免版本冲突导致启动失败）。

```r
install.packages("Matrix")
```

---

## 5. 方法说明

对每个样本：

1. 直接读取 10X 的 `matrix.mtx.gz` + `features.tsv.gz/genes.tsv.gz` + `barcodes.tsv.gz`。
2. 计算每个基因在全部细胞/核上的总和（`rowSums`）。
3. 若同名 gene symbol 重复，按 gene symbol 再次求和。
4. 合并所有样本矩阵，缺失值补 0。

最终得到 single-cell/single-nucleus 聚合后的 bulk-like count data。


---

## 6. pseudo-bulk 分布校正到 bulk（quantile matching + ComBat）

当你已经得到 `allcell_pseudobulk_counts.tsv` 后，可继续运行：

```bash
cd figure_1
unset R_HOME
Rscript match_pseudobulk_to_bulk_distribution.R   /path/to/bulk_counts.csv   /path/to/allcell_pseudobulk_counts.tsv   /path/to/output_dir   22:40
```

参数说明：

1. `bulk_counts.csv`：bulk RNA count 矩阵（第一列为 gene）
2. `allcell_pseudobulk_counts.tsv`：前一步生成的 pseudo-bulk count 矩阵
3. `output_dir`：输出目录
4. `22:40`：可选，指定 bulk 矩阵使用哪些列（示例表示第 22 到 40 列）；不传则默认使用 bulk 全部样本列

也支持环境变量：

- `BULK_FILE`
- `PSEUDO_FILE`
- `OUTDIR`
- `BULK_COLS`

该脚本会：

1. bulk 与 pseudo 取共同基因；
2. 分别计算 TMM-normalized logCPM；
3. 对 pseudo 做 sample-wise quantile matching（向 bulk 平均分布对齐）；
4. 合并 bulk + matched pseudo，并用 ComBat 进行 batch correction；
5. 输出 density/PCA QC 图。

新增输出包括：

- `bulk_logCPM.tsv`
- `pseudobulk_logCPM.tsv`
- `pseudobulk_bulk_like_quantile_matched.tsv`
- `combined_bulk_original_plus_pseudobulk_quantile_matched.tsv`
- `density_before_matching.pdf`
- `density_after_quantile_matching.pdf`
- `PCA_before_matching.pdf`
- `PCA_after_quantile_matching.pdf`
