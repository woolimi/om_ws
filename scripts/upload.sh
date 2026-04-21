#!/usr/bin/env bash
# data/ 안의 데이터셋을 HuggingFace Hub에 업로드
#
# 사용법:
#   ./scripts/upload.sh
#   REPO_ID=woolim/my_task DATASET_ROOT=./data/Pick_up_Doll ./scripts/upload.sh
#
# 환경변수:
#   DATA_DIR       데이터 부모 폴더 (기본: ./data)
#   DATASET_ROOT   업로드할 데이터셋 경로 (비우면 목록에서 선택)
#   REPO_ID        Hub repo_id (비우면 입력 프롬프트)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data}"
DATASET_ROOT="${DATASET_ROOT:-}"
REPO_ID="${REPO_ID:-}"

# DATASET_ROOT 미지정 시 목록에서 선택
if [[ -z "$DATASET_ROOT" ]]; then
  if [[ ! -d "$DATA_DIR" ]]; then
    echo "Error: $DATA_DIR not found."
    exit 1
  fi

  CANDIDATES=()
  for d in "$DATA_DIR"/*/; do
    [[ -d "$d" ]] && [[ -f "${d}meta/info.json" ]] && CANDIDATES+=("$(basename "$d")")
  done

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo "No LeRobot datasets found in $DATA_DIR (need meta/info.json in each folder)."
    exit 1
  fi

  echo "=== $DATA_DIR 에 있는 데이터셋 ==="
  for i in "${!CANDIDATES[@]}"; do
    echo "  $((i + 1))) ${CANDIDATES[$i]}"
  done
  echo ""
  echo -n "업로드할 번호 선택: "
  read -r CHOICE

  if [[ -z "$CHOICE" ]] || ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#CANDIDATES[@]} ]]; then
    echo "Error: 잘못된 선택입니다."
    exit 1
  fi

  SELECTED="${CANDIDATES[$((CHOICE - 1))]}"
  DATASET_ROOT="$DATA_DIR/$SELECTED"
fi

if [[ ! -d "$DATASET_ROOT" ]]; then
  echo "Error: $DATASET_ROOT not found."
  exit 1
fi

if [[ -z "$REPO_ID" ]]; then
  FOLDER_NAME="$(basename "$DATASET_ROOT")"
  DEFAULT_REPO_ID="${HF_USER}/${FOLDER_NAME}"
  echo -n "Hub repo_id (기본: ${DEFAULT_REPO_ID}): "
  read -r REPO_ID
  REPO_ID="${REPO_ID:-${DEFAULT_REPO_ID}}"
fi

echo ""
echo "=== HuggingFace Upload ==="
echo "Dataset: $DATASET_ROOT"
echo "Repo:    $REPO_ID"
echo ""

hf upload "$REPO_ID" "$DATASET_ROOT" --repo-type dataset
