# WGS Somatic Pipeline (Clean Scaffold)

This directory provides a cleaner, project-oriented wrapper around the legacy
bash pipeline kept in `somatic-mutation-analysis_bash_pipeline-main/`.

> Scope note: this scaffold is now standardized for **human hg38 only**.
> Legacy multi-species paths (e.g., mouse/mm10) are intentionally removed from
> active execution defaults to keep the pipeline short and maintainable.

## Goals

- Keep legacy code intact and reproducible.
- Give you a stable interface for your own project.
- Separate configuration from execution logic.
- Support stage-by-stage runs and range runs.

## Structure

```text
pipeline/wgs_somatic/
├── README.md
├── run_pipeline.sh
├── validate_legacy_layout.sh
├── bin/
│   ├── lib.sh
│   └── run_stage.sh
├── config/
│   ├── paths.example.env
│   ├── paths.repo.env
│   └── samples.example.tsv
└── stages/
    ├── 00_export_environment.sh
    ├── 01_check_pairs.sh
    ├── 02_align.sh
    ├── 03_postprocess_bam.sh
    ├── 04_call_variants.sh
    ├── 05_filter_and_orient.sh
    ├── 06_annotation.sh
    └── 07_downstream_analysis.sh
```

## Configuration behavior

- If `--config` is provided, that file must exist.
- If not provided, config resolution order is:
  1. `config/paths.env`
  2. `config/paths.repo.env`
  3. `config/paths.example.env` (warning fallback)

For your own project, create `config/paths.env` from `paths.example.env`.

## Quick start

1. Create your project config:
   - `cp pipeline/wgs_somatic/config/paths.example.env pipeline/wgs_somatic/config/paths.env`
2. Validate required legacy scripts:
   - `bash pipeline/wgs_somatic/validate_legacy_layout.sh --config pipeline/wgs_somatic/config/paths.env`
3. List stage mappings:
   - `bash pipeline/wgs_somatic/bin/run_stage.sh --list`
4. Run all stages:
   - `bash pipeline/wgs_somatic/run_pipeline.sh --config pipeline/wgs_somatic/config/paths.env`
5. Run a stage range (example 03->06):
   - `bash pipeline/wgs_somatic/run_pipeline.sh --from 03 --to 06 --config pipeline/wgs_somatic/config/paths.env`

## Stage mapping

- `00` -> environment export
- `01` -> pair checks
- `02` -> alignment
- `03` -> BAM merge/markdup/BQSR
- `04` -> somatic calling (Mutect2 route)
- `05` -> contamination/orientation/filtering
- `06` -> annotation
- `07` -> downstream analysis

## Notes

- Every stage supports `--config` and `--dry-run`.
- Wrappers currently call legacy scripts directly.
- You can replace internals gradually while keeping stage IDs stable.
