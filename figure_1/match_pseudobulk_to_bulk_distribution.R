suppressPackageStartupMessages({
  library(edgeR)
  library(ggplot2)
  library(sva)
})

############################################################
## 1. 输入参数（优先命令行，其次环境变量，最后默认值）
############################################################

args <- commandArgs(trailingOnly = TRUE)

get_arg <- function(i, default = NULL) {
  if (length(args) >= i && nzchar(args[i])) args[i] else default
}

bulk_file <- get_arg(1, Sys.getenv("BULK_FILE", unset = "bulk_counts.csv"))
pseudo_file <- get_arg(2, Sys.getenv("PSEUDO_FILE", unset = "pseudobulk_allcell_out/allcell_pseudobulk_counts.tsv"))
outdir <- get_arg(3, Sys.getenv("OUTDIR", unset = "bulk_pseudobulk_matched_out"))
bulk_cols <- get_arg(4, Sys.getenv("BULK_COLS", unset = ""))

dir.create(outdir, showWarnings = FALSE, recursive = TRUE)

############################################################
## 2. 读取矩阵函数
############################################################

read_count_matrix <- function(file, sep = NULL) {
  if (is.null(sep)) {
    if (grepl("\\.csv$", file, ignore.case = TRUE)) {
      sep <- ","
    } else {
      sep <- "\t"
    }
  }

  df <- read.table(
    file,
    header = TRUE,
    sep = sep,
    check.names = FALSE,
    stringsAsFactors = FALSE,
    quote = "",
    comment.char = "",
    fill = TRUE
  )

  gene_col <- colnames(df)[1]
  genes <- df[[gene_col]]
  df[[gene_col]] <- NULL

  clean_gene <- function(x) {
    x <- as.character(x)
    x <- trimws(x)
    x <- gsub('^"+|"+$', '', x)
    x <- gsub("^'+|'+$", "", x)
    trimws(x)
  }

  genes <- clean_gene(genes)
  colnames(df) <- clean_gene(colnames(df))

  mat <- as.matrix(df)
  mode(mat) <- "numeric"

  mat_df <- data.frame(gene = genes, mat, check.names = FALSE)
  mat_df <- aggregate(. ~ gene, data = mat_df, FUN = sum)

  genes2 <- mat_df$gene
  mat_df$gene <- NULL

  mat2 <- as.matrix(mat_df)
  rownames(mat2) <- genes2

  mat2
}

parse_bulk_cols <- function(x, n_total) {
  if (!nzchar(x)) return(seq_len(n_total))

  idx <- integer(0)
  parts <- strsplit(x, ",")[[1]]
  for (p in parts) {
    p <- trimws(p)
    if (grepl("^[0-9]+:[0-9]+$", p)) {
      a <- as.integer(strsplit(p, ":")[[1]][1])
      b <- as.integer(strsplit(p, ":")[[1]][2])
      idx <- c(idx, seq.int(a, b))
    } else if (grepl("^[0-9]+$", p)) {
      idx <- c(idx, as.integer(p))
    } else {
      stop("BULK_COLS 格式错误: ", p, "。示例: 22:40 或 1,3,5")
    }
  }

  idx <- unique(idx)
  idx <- idx[idx >= 1 & idx <= n_total]
  if (length(idx) == 0) stop("BULK_COLS 解析后为空，请检查列范围")
  idx
}

############################################################
## 3. 读取 bulk 和 pseudo-bulk counts
############################################################

bulk_counts <- read_count_matrix(bulk_file)
selected_cols <- parse_bulk_cols(bulk_cols, ncol(bulk_counts))
bulk_counts <- bulk_counts[, selected_cols, drop = FALSE]
pseudo_counts <- read_count_matrix(pseudo_file)

cat("Bulk count matrix:\n")
cat("Genes:", nrow(bulk_counts), " Samples:", ncol(bulk_counts), "\n")

cat("Pseudo-bulk count matrix:\n")
cat("Genes:", nrow(pseudo_counts), " Samples:", ncol(pseudo_counts), "\n")

############################################################
## 4. 取共同基因
############################################################

common_genes <- intersect(rownames(bulk_counts), rownames(pseudo_counts))
cat("Common genes:", length(common_genes), "\n")

bulk_counts <- bulk_counts[common_genes, , drop = FALSE]
pseudo_counts <- pseudo_counts[common_genes, , drop = FALSE]

############################################################
## 5. 转成 logCPM
############################################################

to_logCPM <- function(count_mat) {
  dge <- DGEList(counts = count_mat)
  dge <- calcNormFactors(dge, method = "TMM")
  cpm(dge, log = TRUE, prior.count = 1)
}

bulk_logCPM <- to_logCPM(bulk_counts)
pseudo_logCPM <- to_logCPM(pseudo_counts)

write.table(bulk_logCPM, file = file.path(outdir, "bulk_logCPM.tsv"), sep = "\t", quote = FALSE, col.names = NA)
write.table(pseudo_logCPM, file = file.path(outdir, "pseudobulk_logCPM.tsv"), sep = "\t", quote = FALSE, col.names = NA)

############################################################
## 6. sample-wise quantile matching（只调整 pseudo）
############################################################

make_reference_distribution <- function(bulk_expr) {
  sorted_bulk <- apply(bulk_expr, 2, sort, na.last = NA)
  rowMeans(sorted_bulk, na.rm = TRUE)
}

quantile_match_one_sample <- function(x, ref_sorted) {
  ord <- order(x, na.last = TRUE)
  y <- rep(NA_real_, length(x))

  n <- length(x)
  ref_use <- ref_sorted
  if (length(ref_use) != n) {
    ref_use <- approx(
      x = seq_along(ref_sorted),
      y = ref_sorted,
      xout = seq(1, length(ref_sorted), length.out = n),
      ties = "ordered"
    )$y
  }

  y[ord] <- ref_use
  names(y) <- names(x)
  y
}

bulk_ref_distribution <- make_reference_distribution(bulk_logCPM)
pseudo_qmatched <- apply(pseudo_logCPM, 2, quantile_match_one_sample, ref_sorted = bulk_ref_distribution)
pseudo_qmatched <- as.matrix(pseudo_qmatched)
rownames(pseudo_qmatched) <- rownames(pseudo_logCPM)

write.table(pseudo_qmatched, file = file.path(outdir, "pseudobulk_bulk_like_quantile_matched.tsv"), sep = "\t", quote = FALSE, col.names = NA)

############################################################
## 7. 合并 + ComBat batch correction
############################################################

combined_qmatched <- cbind(bulk_logCPM, pseudo_qmatched)
batch <- c(rep("bulk", ncol(bulk_logCPM)), rep("pseudo", ncol(pseudo_qmatched)))

combined_qmatched <- ComBat(
  dat = as.matrix(combined_qmatched),
  batch = batch,
  par.prior = TRUE,
  prior.plots = FALSE
)

write.table(
  combined_qmatched,
  file = file.path(outdir, "combined_bulk_original_plus_pseudobulk_quantile_matched.tsv"),
  sep = "\t",
  quote = FALSE,
  col.names = NA
)

############################################################
## 8. QC 图：density + PCA
############################################################

plot_density <- function(mat1, mat2, name1, name2, outfile) {
  set.seed(1)
  v1 <- as.numeric(mat1)
  v2 <- as.numeric(mat2)

  if (length(v1) > 200000) v1 <- sample(v1, 200000)
  if (length(v2) > 200000) v2 <- sample(v2, 200000)

  df <- data.frame(
    expr = c(v1, v2),
    group = c(rep(name1, length(v1)), rep(name2, length(v2)))
  )

  p <- ggplot(df, aes(x = expr, color = group)) +
    geom_density(linewidth = 0.8) +
    theme_classic() +
    labs(x = "Expression value", y = "Density")

  ggsave(outfile, p, width = 6, height = 4)
}

plot_pca <- function(combined_mat, pseudo_samples, outfile, title) {
  pca <- prcomp(t(combined_mat), scale. = TRUE)
  sample_id <- rownames(pca$x)
  source <- ifelse(sample_id %in% pseudo_samples, "pseudo-bulk", "bulk")

  df <- data.frame(sample_id = sample_id, PC1 = pca$x[, 1], PC2 = pca$x[, 2], source = source)
  p <- ggplot(df, aes(PC1, PC2, color = source, label = sample_id)) +
    geom_point(size = 3) +
    theme_classic() +
    labs(title = title)

  ggsave(outfile, p, width = 6, height = 5)
}

plot_density(bulk_logCPM, pseudo_logCPM, "bulk logCPM", "pseudo logCPM", file.path(outdir, "density_before_matching.pdf"))
plot_density(bulk_logCPM, pseudo_qmatched, "bulk logCPM", "pseudo quantile-matched", file.path(outdir, "density_after_quantile_matching.pdf"))

plot_pca(cbind(bulk_logCPM, pseudo_logCPM), colnames(pseudo_logCPM), file.path(outdir, "PCA_before_matching.pdf"), "Before matching")
plot_pca(combined_qmatched, colnames(pseudo_qmatched), file.path(outdir, "PCA_after_quantile_matching.pdf"), "After quantile matching")

cat("\nDone.\n")
cat("Output directory:", outdir, "\n")
cat("Main outputs:\n")
cat("1. bulk_logCPM.tsv\n")
cat("2. pseudobulk_logCPM.tsv\n")
cat("3. pseudobulk_bulk_like_quantile_matched.tsv\n")
cat("4. combined_bulk_original_plus_pseudobulk_quantile_matched.tsv\n")
