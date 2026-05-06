# Figure 1：snRNA-seq/scRNA-seq 汇总为 bulk-like count data（不过滤基因）

本目录提供一个最小脚本，用于把每个样本的 10X 单细胞/单核表达矩阵按**所有细胞（all-cell）直接求和**，生成样本 × 基因的 pseudo-bulk count 矩阵。

> 关键点：
> - 这一步**不做任何基因过滤**。
> - 这一步**不丢弃任何细胞/细胞核**。
> - 输出是可用于下游 bulk RNA 统计流程的原始 count 矩阵。

---

## 1. 输入文件准备

在运行目录下准备 `tenx_manifest.tsv`（制表符分隔），至少包含两列：

- `sample_id`：样本名（最终会作为 count 矩阵的列名）
- `path`：该样本的 10X 目录路径（目录内应有 `matrix.mtx.gz`、`features.tsv.gz`、`barcodes.tsv.gz`）

示例：

```tsv
sample_id	path
SCCC_01	/data/sccc/SCCC_01/filtered_feature_bc_matrix
SCCC_02	/data/sccc/SCCC_02/filtered_feature_bc_matrix
```

---

## 2. 运行脚本

```bash
cd figure_1
Rscript make_allcell_pseudobulk_from_10x_no_filter.R
```

---

## 3. 输出结果

脚本会在当前目录创建 `pseudobulk_allcell_out/`，包含：

1. `allcell_pseudobulk_counts.tsv`  
   - 第一列 `gene`
   - 后续每列是一个 `sample_id`
   - 值为该基因在该样本所有细胞/核的 UMI 求和

2. `allcell_pseudobulk_qc.tsv`  
   - 每个样本的基础汇总信息（如 `n_cells`、`n_genes`、`total_UMI` 等）
   - 仅用于记录，不参与过滤

---

## 4. 依赖包

R 包：

- `Seurat`
- `Matrix`
- `data.table`
- `dplyr`

如未安装，可先执行：

```r
install.packages(c("Matrix", "data.table", "dplyr"))
# Seurat 通常需按官方说明安装
```

---

## 5. 方法说明（简要）

对每个样本：

1. 读取 10X count matrix。
2. 若为多 assay 数据，优先取 `Gene Expression`。
3. 对每个基因在所有细胞/核上做 `rowSums`。
4. 合并所有样本为一个总矩阵，缺失值补 0。

因此，得到的是“single-cell/single-nucleus 聚合后的 bulk-like count data”。
