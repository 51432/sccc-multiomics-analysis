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
