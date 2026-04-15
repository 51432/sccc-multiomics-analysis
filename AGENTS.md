# AGENTS.md

## Repository purpose
This repository is used for bioinformatics analysis related to cervical small cell carcinoma (SCCC), including WGS and other multi-omics workflows.

## General goals
- Help reorganize legacy analysis code into a cleaner and more maintainable pipeline.
- Preserve the original scientific workflow whenever possible.
- Prefer incremental migration over full rewriting.
- Keep the repository structure clear and modular.

## Communication preferences
- Please explain summaries, migration notes, README content, and code comments in Chinese whenever possible.
- Keep filenames, function names, variable names, and code identifiers in English.
- Use clear and concise language.

## Code editing rules
- Do not delete legacy scripts directly.
- Move outdated or uncertain files into an archive folder instead of removing them.
- Prefer reorganizing and documenting over rewriting.
- Replace hard-coded paths with configurable paths whenever possible.
- Do not change biological or statistical logic unless explicitly requested.

## Workflow preferences
- First inspect and summarize the current workflow before making large changes.
- Group scripts by analysis stage.
- Make the pipeline easier to adapt to a new project environment.
- Add documentation when introducing new wrappers, configs, or directory structures.

# Editing continuity rules
- When a pipeline directory or scaffold has already been created in this repository, continue editing that existing directory instead of creating a new top-level folder, duplicate scaffold, or parallel pipeline implementation.

- Do not create a new pipeline folder merely to apply revisions.
- Prefer modifying the existing files in place.
- If a structural change is necessary, explain why before doing it.
- Avoid duplicating wrappers, configs, or README files unless explicitly requested.

- If previous Codex changes already exist in the repository or in an open PR branch, continue from that implementation rather than rebuilding the same pipeline in another location.

