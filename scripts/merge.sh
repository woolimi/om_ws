#!/usr/bin/env bash
# data/ 안의 여러 데이터셋을 골라 하나로 merge
#
# 사용법:
#   ./scripts/merge.sh
#
# 환경변수:
#   DATA_DIR        데이터 부모 폴더 (기본: ./data)
#   MERGED_REPO_ID  merge 결과 repo_id (기본: 입력 프롬프트)
#
# 종료: Ctrl+C

set -e
cd "$(dirname "$0")/.."

DATA_DIR="${DATA_DIR:-./data}"
MERGED_REPO_ID="${MERGED_REPO_ID:-}"

if [[ ! -d "$DATA_DIR" ]]; then
  echo "Error: $DATA_DIR not found."
  exit 1
fi

# data/ 아래에서 meta/info.json 이 있는 폴더만 (lerobot 데이터셋)
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
echo -n "merge 할 번호 입력 (공백 또는 쉼표 구분, 예: 1 2 3 또는 1,2,3): "
read -r CHOICE

if [[ -z "$CHOICE" ]]; then
  echo "Error: 선택이 비어 있습니다."
  exit 1
fi

# 번호 파싱: "1 2 3" 또는 "1,2,3" -> 선택된 폴더 이름 배열
SELECTED=()
CHOICE="${CHOICE//,/ }"
for num in $CHOICE; do
  num=$(echo "$num" | tr -d ' ')
  if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -ge 1 ]] && [[ "$num" -le ${#CANDIDATES[@]} ]]; then
    SELECTED+=("${CANDIDATES[$((num - 1))]}")
  fi
done

# 중복 제거
SELECTED_UNIQ=()
for s in "${SELECTED[@]}"; do
  if [[ " ${SELECTED_UNIQ[*]} " != *" $s "* ]]; then
    SELECTED_UNIQ+=("$s")
  fi
done

if [[ ${#SELECTED_UNIQ[@]} -lt 2 ]]; then
  echo "Error: merge 하려면 최소 2개를 선택해야 합니다."
  exit 1
fi

if [[ -z "$MERGED_REPO_ID" ]]; then
  echo -n "merge 결과 repo_id (기본: ${HF_USER}/merged): "
  read -r MERGED_REPO_ID
  MERGED_REPO_ID="${MERGED_REPO_ID:-${HF_USER}/merged}"
fi

echo ""
echo "선택: ${SELECTED_UNIQ[*]}"
echo "출력: $MERGED_REPO_ID"
echo ""

python scripts/merge_datasets_local.py \
  --data-dir "$DATA_DIR" \
  --folders "${SELECTED_UNIQ[@]}" \
  --output-repo-id "$MERGED_REPO_ID"

echo ""
echo "훈련 시 예: REPO_ID=$MERGED_REPO_ID DATASET_ROOT=$DATA_DIR/${MERGED_REPO_ID//\//_} ./scripts/train.sh"
