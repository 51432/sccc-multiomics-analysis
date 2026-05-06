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
