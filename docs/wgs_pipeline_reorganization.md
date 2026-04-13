# WGS Legacy Pipeline Reorganization Plan

## What changed

- Added a clean wrapper pipeline at `pipeline/wgs_somatic/`.
- Added config-first interface (`config/*.env`) and shared runtime library.
- Added centralized stage router (`bin/run_stage.sh`) and full runner (`run_pipeline.sh`).
- Added `validate_legacy_layout.sh` for preflight checks.
- Refactored stage mappings into a single source of truth (`run_stage.sh --list`).

## Why this pattern

This enables immediate project reuse without risky rewrites. You can migrate one
stage at a time while preserving output parity against legacy execution.

## Practical workflow for your own project

1. **Prepare config and sample sheet**
   - Duplicate `paths.example.env` to `paths.env` and customize.
   - Freeze sample sheet schema early to avoid downstream drift.
2. **Preflight validation**
   - Run `validate_legacy_layout.sh` to verify required legacy scripts exist.
3. **Execution mode selection**
   - Use `stages/*.sh` wrappers for focused debugging.
   - Use `run_pipeline.sh` for routine full runs and stage ranges.
4. **Incremental modernization**
   - Replace logic behind each stage ID while keeping stage ID contracts stable.
5. **Hardening**
   - Add tool version pinning and QC gates before large-scale project runs.

## Legacy-to-clean mapping

Use the source-of-truth command:

```bash
bash pipeline/wgs_somatic/bin/run_stage.sh --list
```

This prints `stage_id`, logical stage name, and mapped legacy script(s).
