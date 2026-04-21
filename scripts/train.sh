#!/usr/bin/env bash
# LeRobot 모델 훈련 (ACT 정책)
#
# 사용법:
#   ./scripts/train.sh
#   REPO_ID=woolimi/trainset DATASET_ROOT=./data/trainset MODEL_VERSION=act_v1 ./scripts/train.sh
#
# 환경변수:
#   DATA_DIR       데이터 부모 폴더 (기본: ./data)
#   REPO_ID        데이터셋 repo_id (비우면 목록에서 선택)
#   DATASET_ROOT   데이터셋 경로
#   MODEL_VERSION  모델 이름 (예: act_v1)
#   OUTPUT_DIR     출력 폴더 (기본: outputs/train/<MODEL_VERSION>)
#   POLICY_DEVICE  cuda / mps / cpu
#   NUM_WORKERS    dataloader worker 수 (기본: 4)
#   STEPS          훈련 step 수 (기본: 400000)
#   BATCH_SIZE     배치 크기 (기본: 16)
#   SAVE_FREQ      체크포인트 저장 빈도 (기본: 3000)
#   WANDB_MODE     online / offline / disabled (기본: offline)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

# CUDA Memory Fragmentation 완화
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,max_split_size_mb:256

# Mixed Precision (bf16)
export ACCELERATE_MIXED_PRECISION=bf16

DATA_DIR="${DATA_DIR:-./data}"

if [[ -z "${REPO_ID:-}" ]] || [[ -z "${DATASET_ROOT:-}" ]] || [[ -z "${MODEL_VERSION:-}" ]]; then
  if [[ ! -d "$DATA_DIR" ]]; then
    echo "Error: $DATA_DIR not found."
    exit 1
  fi

  CANDIDATES=()
  for d in "$DATA_DIR"/*/; do
    [[ -d "$d" ]] && [[ -f "${d}meta/info.json" ]] && CANDIDATES+=("$(basename "$d")")
  done

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No LeRobot datasets in $DATA_DIR."
    exit 1
  fi

  echo "=== 훈련 데이터셋 선택 ==="
  for i in "${!CANDIDATES[@]}"; do
    echo "  $((i + 1))) ${CANDIDATES[$i]}"
  done

  echo -n "데이터셋 번호: "
  read -r NUM

  if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ "$NUM" -lt 1 ]] || [[ "$NUM" -gt ${#CANDIDATES[@]} ]]; then
    echo "Error: 잘못된 선택입니다."
    exit 1
  fi

  SELECTED_FOLDER="${CANDIDATES[$((NUM - 1))]}"
  DATASET_ROOT="./data/${SELECTED_FOLDER}"
  REPO_ID="${REPO_ID:-${HF_USER}/${SELECTED_FOLDER}}"

  echo -n "모델 이름 (기본: act_${SELECTED_FOLDER}): "
  read -r MODEL_VERSION
  MODEL_VERSION="${MODEL_VERSION:-act_${SELECTED_FOLDER}}"
fi

OUTPUT_DIR="${OUTPUT_DIR:-outputs/train/${MODEL_VERSION}}"
JOB_NAME="${JOB_NAME:-${MODEL_VERSION}}"

if [[ "$(uname -s)" == "Linux" ]]; then
  POLICY_DEVICE="${POLICY_DEVICE:-cuda}"
else
  POLICY_DEVICE="${POLICY_DEVICE:-mps}"
fi

NUM_WORKERS="${NUM_WORKERS:-4}"
STEPS="${STEPS:-400000}"
BATCH_SIZE="${BATCH_SIZE:-4}"
SAVE_FREQ="${SAVE_FREQ:-5000}"
WANDB_ENABLE="${WANDB_ENABLE:-false}"
export WANDB_MODE="${WANDB_MODE:-offline}"

echo ""
echo "=== LeRobot Train ==="
echo "Dataset: repo_id=${REPO_ID}  root=${DATASET_ROOT}"
echo "Model:   ${MODEL_VERSION}"
echo "Output:  ${OUTPUT_DIR}"
echo "Device:  ${POLICY_DEVICE}  num_workers=${NUM_WORKERS}"
echo "Steps:   ${STEPS}  batch_size=${BATCH_SIZE}"
echo ""

lerobot-train \
  --dataset.repo_id="${REPO_ID}" \
  --dataset.root="${DATASET_ROOT}" \
  --policy.type=act \
  --policy.device="${POLICY_DEVICE}" \
  --policy.push_to_hub=false \
  --output_dir="${OUTPUT_DIR}" \
  --job_name="${JOB_NAME}" \
  --dataset.image_transforms.enable=true \
  --wandb.enable="${WANDB_ENABLE}" \
  --steps="${STEPS}" \
  --batch_size="${BATCH_SIZE}" \
  --num_workers="${NUM_WORKERS}" \
  --save_checkpoint=true \
  --save_freq="${SAVE_FREQ}" \
  --dataset.video_backend=torchcodec \
  "$@"
