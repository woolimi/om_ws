#!/usr/bin/env bash
# 기존 체크포인트 가중치로 새 데이터셋 fine-tuning
# (train_resume.sh와 달리 step/optimizer는 초기화되고, policy 가중치만 이어받음)
#
# 사용법:
#   ./scripts/train_finetune.sh
#   (베이스 모델 → 체크포인트 → 데이터셋 → 새 모델 이름 대화형 선택)
#
#   BASE_CKPT=outputs/train/act_colorset/checkpoints/last/pretrained_model \
#   DATASET_ROOT=./data/colorset_basket_moved \
#   MODEL_VERSION=act_colorset_basket_moved \
#   ./scripts/train_finetune.sh
#
# 환경변수:
#   BASE_CKPT       베이스 pretrained_model 디렉토리 (비우면 대화형)
#   REPO_ID         데이터셋 repo_id (기본: ${HF_USER}/<폴더명>)
#   DATASET_ROOT    데이터셋 경로 (비우면 대화형)
#   MODEL_VERSION   새 모델 이름 (비우면 대화형)
#   OUTPUT_DIR      출력 폴더 (기본: outputs/train/<MODEL_VERSION>)
#   TRAIN_DIR       훈련 출력 루트 (기본: outputs/train)
#   DATA_DIR        데이터 부모 폴더 (기본: ./data)
#   POLICY_DEVICE   cuda / mps / cpu
#   NUM_WORKERS     dataloader worker 수 (기본: 4)
#   STEPS           훈련 step 수 (기본: 100000, fine-tuning이라 train.sh보다 짧음)
#   BATCH_SIZE      배치 크기 (기본: 4)
#   SAVE_FREQ       체크포인트 저장 빈도 (기본: 5000)
#   WANDB_MODE      online / offline / disabled (기본: offline)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,max_split_size_mb:256
export ACCELERATE_MIXED_PRECISION=bf16

TRAIN_DIR="${TRAIN_DIR:-outputs/train}"
DATA_DIR="${DATA_DIR:-./data}"

# --- 베이스 체크포인트 선택 ---
if [[ -z "${BASE_CKPT:-}" ]]; then
  if [[ ! -d "$TRAIN_DIR" ]]; then
    echo "Error: $TRAIN_DIR not found. 먼저 train.sh로 베이스 모델을 훈련하세요."
    exit 1
  fi

  RUNS=()
  for d in "$TRAIN_DIR"/*/; do
    [[ -d "$d" ]] && [[ -d "${d}checkpoints" ]] && RUNS+=("$(basename "$d")")
  done

  if [[ ${#RUNS[@]} -eq 0 ]]; then
    echo "No run with checkpoints in $TRAIN_DIR."
    exit 1
  fi

  echo "=== 베이스 모델 선택 ==="
  for i in "${!RUNS[@]}"; do
    echo "  $((i + 1))) ${RUNS[$i]}"
  done
  echo -n "런 번호: "
  read -r RUN_NUM
  if ! [[ "$RUN_NUM" =~ ^[0-9]+$ ]] || [[ "$RUN_NUM" -lt 1 ]] || [[ "$RUN_NUM" -gt ${#RUNS[@]} ]]; then
    echo "Error: 잘못된 번호."
    exit 1
  fi
  BASE_RUN="${RUNS[$((RUN_NUM - 1))]}"
  CKPT_DIR="${TRAIN_DIR}/${BASE_RUN}/checkpoints"

  STEPS_LIST=()
  for d in "$CKPT_DIR"/*/; do
    if [[ -d "$d" ]] && [[ -f "${d}pretrained_model/model.safetensors" ]]; then
      STEPS_LIST+=("$(basename "$d")")
    fi
  done
  # last symlink 우선, 나머지는 숫자순
  STEPS_LIST=($(printf '%s\n' "${STEPS_LIST[@]}" | awk '/^last$/{print; next}{print}' | awk '!/^last$/' | sort -n))
  if [[ -f "${CKPT_DIR}/last/pretrained_model/model.safetensors" ]]; then
    STEPS_LIST=("last" "${STEPS_LIST[@]}")
  fi

  if [[ ${#STEPS_LIST[@]} -eq 0 ]]; then
    echo "Error: No checkpoint with model.safetensors in $CKPT_DIR"
    exit 1
  fi

  echo ""
  echo "=== 체크포인트 선택 ==="
  for i in "${!STEPS_LIST[@]}"; do
    echo "  $((i + 1))) ${STEPS_LIST[$i]}"
  done
  echo -n "체크포인트 번호: "
  read -r STEP_NUM
  if ! [[ "$STEP_NUM" =~ ^[0-9]+$ ]] || [[ "$STEP_NUM" -lt 1 ]] || [[ "$STEP_NUM" -gt ${#STEPS_LIST[@]} ]]; then
    echo "Error: 잘못된 번호."
    exit 1
  fi
  STEP_NAME="${STEPS_LIST[$((STEP_NUM - 1))]}"
  BASE_CKPT="${CKPT_DIR}/${STEP_NAME}/pretrained_model"
fi

if [[ ! -f "${BASE_CKPT}/model.safetensors" ]]; then
  echo "Error: ${BASE_CKPT}/model.safetensors not found."
  exit 1
fi

# --- 데이터셋 선택 ---
if [[ -z "${DATASET_ROOT:-}" ]]; then
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

  echo ""
  echo "=== 데이터셋 선택 ==="
  for i in "${!CANDIDATES[@]}"; do
    echo "  $((i + 1))) ${CANDIDATES[$i]}"
  done
  echo -n "데이터셋 번호: "
  read -r NUM
  if ! [[ "$NUM" =~ ^[0-9]+$ ]] || [[ "$NUM" -lt 1 ]] || [[ "$NUM" -gt ${#CANDIDATES[@]} ]]; then
    echo "Error: 잘못된 선택."
    exit 1
  fi
  SELECTED_FOLDER="${CANDIDATES[$((NUM - 1))]}"
  DATASET_ROOT="./data/${SELECTED_FOLDER}"
  REPO_ID="${REPO_ID:-${HF_USER}/${SELECTED_FOLDER}}"
else
  SELECTED_FOLDER="$(basename "$DATASET_ROOT")"
  REPO_ID="${REPO_ID:-${HF_USER}/${SELECTED_FOLDER}}"
fi

# --- 모델 이름 ---
if [[ -z "${MODEL_VERSION:-}" ]]; then
  DEFAULT_NAME="act_${SELECTED_FOLDER}"
  echo ""
  echo -n "새 모델 이름 (기본: ${DEFAULT_NAME}): "
  read -r MODEL_VERSION
  MODEL_VERSION="${MODEL_VERSION:-$DEFAULT_NAME}"
fi

OUTPUT_DIR="${OUTPUT_DIR:-outputs/train/${MODEL_VERSION}}"
JOB_NAME="${JOB_NAME:-${MODEL_VERSION}}"

if [[ -d "$OUTPUT_DIR" ]]; then
  echo ""
  echo "경고: $OUTPUT_DIR 가 이미 존재합니다. 덮어쓰면 기존 체크포인트가 손상될 수 있습니다."
  echo -n "계속? (y/N): "
  read -r CONFIRM
  [[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "중단."; exit 1; }
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  POLICY_DEVICE="${POLICY_DEVICE:-cuda}"
else
  POLICY_DEVICE="${POLICY_DEVICE:-mps}"
fi

NUM_WORKERS="${NUM_WORKERS:-4}"
STEPS="${STEPS:-100000}"
BATCH_SIZE="${BATCH_SIZE:-4}"
SAVE_FREQ="${SAVE_FREQ:-5000}"
WANDB_ENABLE="${WANDB_ENABLE:-false}"
export WANDB_MODE="${WANDB_MODE:-offline}"

echo ""
echo "=== LeRobot Fine-tune ==="
echo "Base:    ${BASE_CKPT}"
echo "Dataset: repo_id=${REPO_ID}  root=${DATASET_ROOT}"
echo "Model:   ${MODEL_VERSION}"
echo "Output:  ${OUTPUT_DIR}"
echo "Device:  ${POLICY_DEVICE}  num_workers=${NUM_WORKERS}"
echo "Steps:   ${STEPS}  batch_size=${BATCH_SIZE}"
echo ""

lerobot-train \
  --policy.path="${BASE_CKPT}" \
  --policy.device="${POLICY_DEVICE}" \
  --policy.push_to_hub=false \
  --dataset.repo_id="${REPO_ID}" \
  --dataset.root="${DATASET_ROOT}" \
  --dataset.image_transforms.enable=true \
  --dataset.video_backend=torchcodec \
  --output_dir="${OUTPUT_DIR}" \
  --job_name="${JOB_NAME}" \
  --wandb.enable="${WANDB_ENABLE}" \
  --steps="${STEPS}" \
  --batch_size="${BATCH_SIZE}" \
  --num_workers="${NUM_WORKERS}" \
  --save_checkpoint=true \
  --save_freq="${SAVE_FREQ}" \
  "$@"
