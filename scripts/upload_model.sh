#!/usr/bin/env bash
# 훈련된 모델을 HuggingFace Hub에 업로드
#
# 사용법:
#   ./scripts/upload_model.sh
#   REPO_ID=woolimi/act_pick MODEL_PATH=outputs/train/act_trainset ./scripts/upload_model.sh
#
# 환경변수:
#   TRAIN_DIR      훈련 출력 폴더 (기본: outputs/train)
#   MODEL_PATH     업로드할 모델 런 경로 (비우면 목록에서 선택)
#   CHECKPOINT     체크포인트 이름 (last, 400000 등. 비우면 선택)
#   REPO_ID        Hub repo_id (비우면 입력 프롬프트)
#   INCLUDE_ALL    true: 런 전체 업로드(checkpoints 전부). false: 선택한 체크포인트만 (기본: false)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

TRAIN_DIR="${TRAIN_DIR:-outputs/train}"
MODEL_PATH="${MODEL_PATH:-}"
CHECKPOINT="${CHECKPOINT:-}"
REPO_ID="${REPO_ID:-}"
INCLUDE_ALL="${INCLUDE_ALL:-false}"

# MODEL_PATH 미지정 시 목록에서 선택
if [[ -z "$MODEL_PATH" ]]; then
  if [[ ! -d "$TRAIN_DIR" ]]; then
    echo "Error: $TRAIN_DIR not found."
    exit 1
  fi

  RUNS=()
  for d in "$TRAIN_DIR"/*/; do
    [[ -d "$d" ]] && [[ -d "${d}checkpoints" ]] && RUNS+=("$(basename "$d")")
  done

  if [[ ${#RUNS[@]} -eq 0 ]]; then
    echo "No trained models in $TRAIN_DIR."
    exit 1
  fi

  echo "=== $TRAIN_DIR 에 있는 모델 ==="
  for i in "${!RUNS[@]}"; do
    echo "  $((i + 1))) ${RUNS[$i]}"
  done
  echo ""
  echo -n "업로드할 번호: "
  read -r CHOICE

  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#RUNS[@]} ]]; then
    echo "Error: 잘못된 선택입니다."
    exit 1
  fi

  MODEL_PATH="$TRAIN_DIR/${RUNS[$((CHOICE - 1))]}"
fi

if [[ ! -d "$MODEL_PATH" ]]; then
  echo "Error: $MODEL_PATH not found."
  exit 1
fi

MODEL_NAME="$(basename "$MODEL_PATH")"

# 전체 런 업로드 모드
if [[ "$INCLUDE_ALL" == "true" ]]; then
  UPLOAD_PATH="$MODEL_PATH"
  echo "업로드 대상: 런 전체 ($MODEL_PATH)"
else
  # 체크포인트 선택
  if [[ -z "$CHECKPOINT" ]]; then
    CKPTS=()
    for d in "$MODEL_PATH/checkpoints"/*/; do
      [[ -d "${d}pretrained_model" ]] && CKPTS+=("$(basename "$d")")
    done
    CKPTS=($(printf '%s\n' "${CKPTS[@]}" | sort -n))

    if [[ ${#CKPTS[@]} -eq 0 ]]; then
      echo "Error: $MODEL_PATH/checkpoints/ 아래에 pretrained_model이 없습니다."
      exit 1
    fi

    echo ""
    echo "=== 체크포인트 선택 ==="
    for i in "${!CKPTS[@]}"; do
      echo "  $((i + 1))) ${CKPTS[$i]}"
    done
    echo ""
    echo -n "번호 (기본=last): "
    read -r CP_CHOICE

    if [[ -z "$CP_CHOICE" ]]; then
      # last 체크포인트 찾기
      for c in "${CKPTS[@]}"; do
        [[ "$c" == "last" ]] && CHECKPOINT="$c" && break
      done
      [[ -z "$CHECKPOINT" ]] && CHECKPOINT="${CKPTS[-1]}"
    elif [[ "$CP_CHOICE" =~ ^[0-9]+$ ]] && [[ "$CP_CHOICE" -ge 1 ]] && [[ "$CP_CHOICE" -le ${#CKPTS[@]} ]]; then
      CHECKPOINT="${CKPTS[$((CP_CHOICE - 1))]}"
    else
      echo "Error: 잘못된 선택입니다."
      exit 1
    fi
  fi

  UPLOAD_PATH="$MODEL_PATH/checkpoints/$CHECKPOINT/pretrained_model"
  if [[ ! -d "$UPLOAD_PATH" ]]; then
    echo "Error: $UPLOAD_PATH not found."
    exit 1
  fi
  echo "업로드 대상: $CHECKPOINT 체크포인트 ($UPLOAD_PATH)"
fi

# REPO_ID 입력
if [[ -z "$REPO_ID" ]]; then
  DEFAULT_REPO_ID="${HF_USER}/${MODEL_NAME}"
  [[ "$INCLUDE_ALL" != "true" ]] && DEFAULT_REPO_ID="${HF_USER}/${MODEL_NAME}-${CHECKPOINT}"
  echo ""
  echo -n "Hub repo_id (기본: ${DEFAULT_REPO_ID}): "
  read -r REPO_ID
  REPO_ID="${REPO_ID:-${DEFAULT_REPO_ID}}"
fi

echo ""
echo "=== HuggingFace Model Upload ==="
echo "Model:  $UPLOAD_PATH"
echo "Repo:   $REPO_ID"
echo ""

hf upload "$REPO_ID" "$UPLOAD_PATH" --repo-type model
