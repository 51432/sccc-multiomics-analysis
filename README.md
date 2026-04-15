# sccc-multiomics-analysis

本仓库用于宫颈小细胞癌（SCCC）的多组学分析、分子分型及整合分析相关代码与流程管理。

## 仓库内容

本仓库主要包括以下内容：

- `pipeline/wgs_somatic/`：重构后的 WGS 体细胞突变流程（配置、预检、分阶段与整流程入口）
- `somatic-mutation-analysis_bash_pipeline-main/`：历史 Bash 流程（保留用于兼容与结果复现）
- `data/`：输入数据、整理后的数据及样本信息
- `results/`：分析结果输出
- `figures/`：图表及论文相关图片文件
- `docs/`：分析说明、流程记录及补充文档
- `notebooks/`：探索性分析笔记

## WGS 流程重构说明

为了便于在新项目中复用，新增 `pipeline/wgs_somatic/`，核心能力包括：

1. `config/`：路径与样本模板（含 repo 本地默认配置）。
2. `validate_legacy_layout.sh`：运行前检查历史脚本是否齐全。
3. `stages/`：分步骤执行入口（00–07）。
4. `run_pipeline.sh`：支持按阶段区间批量运行。
5. `bin/`：共享参数解析、配置加载、stage 映射与 dry-run 逻辑。

快速开始：

```bash
cp pipeline/wgs_somatic/config/paths.example.env pipeline/wgs_somatic/config/paths.env
bash pipeline/wgs_somatic/validate_legacy_layout.sh --config pipeline/wgs_somatic/config/paths.env
bash pipeline/wgs_somatic/run_pipeline.sh --config pipeline/wgs_somatic/config/paths.env --dry-run
```

详见：`pipeline/wgs_somatic/README.md` 与 `docs/wgs_pipeline_reorganization.md`。

## 当前物种范围说明（重要）

WGS pipeline 已统一简化为**仅支持人类样本（human/hg38）**。为降低维护成本，历史 `mouse/mm10` 及其它非人类分支逻辑已在主流程中清理，不再作为可选路径保留。
