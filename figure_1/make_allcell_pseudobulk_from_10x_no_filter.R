suppressPackageStartupMessages({
  library(Seurat)
  library(Matrix)
  library(data.table)
  library(dplyr)
})

manifest_file <- "tenx_manifest.tsv"
outdir <- "pseudobulk_allcell_out"
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

manifest <- fread(manifest_file, sep = "\t", header = TRUE, data.table = FALSE)

required_cols <- c("sample_id", "path")
missing_cols <- setdiff(required_cols, colnames(manifest))
if (length(missing_cols) > 0) {
  stop("manifest 缺少列: ", paste(missing_cols, collapse = ", "))
}

pb_list <- list()
qc_list <- list()

for (i in seq_len(nrow(manifest))) {
  sample_id <- manifest$sample_id[i]
  tenx_path <- manifest$path[i]

  message("Reading sample: ", sample_id)
  message("Path: ", tenx_path)

  counts <- Read10X(
    data.dir = tenx_path,
    gene.column = 2,
    unique.features = TRUE
  )

  # 如果是多 assay 10X 数据，只取 Gene Expression
  if (is.list(counts)) {
    if ("Gene Expression" %in% names(counts)) {
      counts <- counts[["Gene Expression"]]
    } else {
      counts <- counts[[1]]
    }
  }

  # 基础 QC 指标，但不强制过滤，保留所有 cells/nuclei
  nCount <- Matrix::colSums(counts)
  nFeature <- Matrix::colSums(counts > 0)

  # all-cell pseudo-bulk: 每个基因在该样本所有细胞/核中求和
  pb_counts <- Matrix::rowSums(counts)

  pb_df <- data.frame(
    gene = names(pb_counts),
    count = as.numeric(pb_counts),
    stringsAsFactors = FALSE
  )

  colnames(pb_df)[2] <- sample_id
  pb_list[[sample_id]] <- pb_df

  qc_list[[sample_id]] <- data.frame(
    sample_id = sample_id,
    n_cells = ncol(counts),
    n_genes = nrow(counts),
    total_UMI = sum(counts),
    median_nCount = median(nCount),
    median_nFeature = median(nFeature),
    mean_nCount = mean(nCount),
    mean_nFeature = mean(nFeature),
    stringsAsFactors = FALSE
  )
}

# 合并所有样本的 pseudo-bulk counts
pseudobulk_counts <- Reduce(function(x, y) {
  full_join(x, y, by = "gene")
}, pb_list)

pseudobulk_counts[is.na(pseudobulk_counts)] <- 0

qc_df <- bind_rows(qc_list)

write.table(
  pseudobulk_counts,
  file = file.path(outdir, "allcell_pseudobulk_counts.tsv"),
  sep = "\t",
  quote = FALSE,
  row.names = FALSE
)

write.table(
  qc_df,
  file = file.path(outdir, "allcell_pseudobulk_qc.tsv"),
  sep = "\t",
  quote = FALSE,
  row.names = FALSE
)

message("Done.")
message("Output count matrix: ", file.path(outdir, "allcell_pseudobulk_counts.tsv"))
message("Output QC table: ", file.path(outdir, "allcell_pseudobulk_qc.tsv"))
