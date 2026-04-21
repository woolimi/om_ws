#!/usr/bin/env bash
# 체크포인트에서 훈련 이어하기 (train.sh로 저장된 체크포인트 사용)
#
# 사용법:
#   ./scripts/train_resume.sh
#   (런 선택 → 체크포인트 번호 선택)
#
# 환경변수:
#   TRAIN_DIR    훈련 출력 폴더 (기본: outputs/train)
#   CONFIG_PATH  train_config.json 경로를 직접 지정 시 대화형 스킵
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True,max_split_size_mb:256
export ACCELERATE_MIXED_PRECISION=bf16

TRAIN_DIR="${TRAIN_DIR:-outputs/train}"

if [[ -n "${CONFIG_PATH:-}" ]]; then
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "Error: CONFIG_PATH not found: $CONFIG_PATH"
    exit 1
  fi
  echo "Resume from: $CONFIG_PATH"
  lerobot-train --resume=true --config_path="${CONFIG_PATH}" "$@"
  exit 0
fi

if [[ ! -d "$TRAIN_DIR" ]]; then
  echo "Error: $TRAIN_DIR not found. 먼저 train.sh로 훈련하세요."
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

echo "=== 이어서 훈련할 런 선택 ==="
for i in "${!RUNS[@]}"; do
  echo "  $((i + 1))) ${RUNS[$i]}"
done
echo ""
echo -n "런 번호: "
read -r RUN_NUM
if ! [[ "$RUN_NUM" =~ ^[0-9]+$ ]] || [[ "$RUN_NUM" -lt 1 ]] || [[ "$RUN_NUM" -gt ${#RUNS[@]} ]]; then
  echo "Error: 잘못된 번호."
  exit 1
fi
RUN_NAME="${RUNS[$((RUN_NUM - 1))]}"
RUN_DIR="${TRAIN_DIR}/${RUN_NAME}"
CKPT_DIR="${RUN_DIR}/checkpoints"

STEPS=()
for d in "$CKPT_DIR"/*/; do
  if [[ -d "$d" ]] && [[ -f "${d}pretrained_model/train_config.json" ]]; then
    STEPS+=("$(basename "$d")")
  fi
done
STEPS=($(printf '%s\n' "${STEPS[@]}" | sort -n))

if [[ ${#STEPS[@]} -eq 0 ]]; then
  echo "Error: No checkpoint with train_config.json in $CKPT_DIR"
  exit 1
fi

echo ""
echo "=== 이어갈 체크포인트 선택 ==="
for i in "${!STEPS[@]}"; do
  echo "  $((i + 1))) ${STEPS[$i]}"
done
echo ""
echo -n "체크포인트 번호: "
read -r STEP_NUM
if ! [[ "$STEP_NUM" =~ ^[0-9]+$ ]] || [[ "$STEP_NUM" -lt 1 ]] || [[ "$STEP_NUM" -gt ${#STEPS[@]} ]]; then
  echo "Error: 잘못된 번호."
  exit 1
fi
STEP_NAME="${STEPS[$((STEP_NUM - 1))]}"
CONFIG_PATH="${RUN_DIR}/checkpoints/${STEP_NAME}/pretrained_model/train_config.json"

echo ""
echo "Resume from: $CONFIG_PATH"
echo ""

lerobot-train --resume=true --config_path="${CONFIG_PATH}" "$@"
