suppressPackageStartupMessages({
  library(Matrix)
})

manifest_file <- "tenx_manifest.tsv"
outdir <- "pseudobulk_allcell_out"
dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

manifest <- read.delim(
  manifest_file,
  header = TRUE,
  sep = "\t",
  stringsAsFactors = FALSE,
  check.names = FALSE
)

if (!all(c("sample_id", "path") %in% colnames(manifest))) {
  stop("tenx_manifest.tsv 必须包含 sample_id 和 path 两列")
}

read_10x_counts <- function(path) {
  matrix_file <- file.path(path, "matrix.mtx.gz")
  feature_file <- file.path(path, "features.tsv.gz")
  barcode_file <- file.path(path, "barcodes.tsv.gz")

  if (!file.exists(feature_file)) {
    feature_file <- file.path(path, "genes.tsv.gz")
  }

  if (!file.exists(matrix_file)) {
    stop("找不到 matrix.mtx.gz: ", matrix_file)
  }
  if (!file.exists(feature_file)) {
    stop("找不到 features.tsv.gz 或 genes.tsv.gz: ", path)
  }
  if (!file.exists(barcode_file)) {
    stop("找不到 barcodes.tsv.gz: ", barcode_file)
  }

  message("Reading matrix: ", matrix_file)

  mat <- readMM(gzfile(matrix_file))

  features <- read.delim(
    gzfile(feature_file),
    header = FALSE,
    stringsAsFactors = FALSE
  )

  barcodes <- read.delim(
    gzfile(barcode_file),
    header = FALSE,
    stringsAsFactors = FALSE
  )

  if (ncol(features) >= 2) {
    gene_names <- features[[2]]
  } else {
    gene_names <- features[[1]]
  }

  rownames(mat) <- make.unique(gene_names)
  colnames(mat) <- barcodes[[1]]

  list(
    counts = mat,
    gene_symbols = gene_names
  )
}

pb_list <- list()
qc_list <- list()

for (i in seq_len(nrow(manifest))) {
  sample_id <- manifest$sample_id[i]
  path <- manifest$path[i]

  message("======================================")
  message("Processing sample: ", sample_id)
  message("Path: ", path)

  x <- read_10x_counts(path)
  counts <- x$counts
  gene_symbols <- x$gene_symbols

  nCount <- Matrix::colSums(counts)
  nFeature <- Matrix::colSums(counts > 0)

  pb_counts <- Matrix::rowSums(counts)

  pb_df <- data.frame(
    gene = gene_symbols,
    count = as.numeric(pb_counts),
    stringsAsFactors = FALSE
  )

  pb_df <- aggregate(
    count ~ gene,
    data = pb_df,
    FUN = sum
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

pseudobulk_counts <- Reduce(function(x, y) {
  merge(x, y, by = "gene", all = TRUE)
}, pb_list)

pseudobulk_counts[is.na(pseudobulk_counts)] <- 0

qc_df <- do.call(rbind, qc_list)

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

message("======================================")
message("Done.")
message("Output count matrix: ", file.path(outdir, "allcell_pseudobulk_counts.tsv"))
message("Output QC table: ", file.path(outdir, "allcell_pseudobulk_qc.tsv"))
