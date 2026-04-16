#!/usr/bin/env bash
#SBATCH --job-name=sccc_somatic_array
#SBATCH --partition=cpu1
#SBATCH --cpus-per-task=12
#SBATCH --mem=40G
#SBATCH --output=logs/slurm/array_%A_%a.out
#SBATCH --error=logs/slurm/array_%A_%a.err


# 以提交目录为工作目录（非常重要）
cd "${SLURM_SUBMIT_DIR}"

# 项目目录来自 submit 脚本传入
ROOT="${PROJECT_DIR:-${SLURM_SUBMIT_DIR}}"

mkdir -p logs/slurm
bash "${ROOT}/02_run_sample_task.sh"
