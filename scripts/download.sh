#!/usr/bin/env bash
# HuggingFace Hub에서 데이터셋 다운로드
#
# 사용법:
#   ./scripts/download.sh
#   REPO_ID=woolimi/trainset ./scripts/download.sh
#
# 환경변수:
#   REPO_ID        Hub repo_id (비우면 입력 프롬프트)
#   DATASET_ROOT   저장 경로 (기본: ./data/<데이터셋명>)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

REPO_ID="${REPO_ID:-}"
DATASET_ROOT="${DATASET_ROOT:-}"

if [[ -z "$REPO_ID" ]]; then
  echo -n "Hub repo_id (예: woolimi/trainset): "
  read -r REPO_ID
  if [[ -z "$REPO_ID" ]]; then
    echo "Error: REPO_ID is required."
    exit 1
  fi
fi

if [[ -z "$DATASET_ROOT" ]]; then
  DATASET_NAME="${REPO_ID##*/}"
  DATASET_ROOT="./data/${DATASET_NAME}"
fi

echo ""
echo "=== HuggingFace Download ==="
echo "Repo:    $REPO_ID"
echo "Output:  $DATASET_ROOT"
echo ""

hf download "$REPO_ID" --repo-type dataset --local-dir "$DATASET_ROOT"
