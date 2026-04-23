#!/usr/bin/env bash
# LeRobot 데이터 수집 — 리더암으로 조작하면서 에피소드 녹화
#
# 카메라:
#   wrist: Innomaker-U20CAM-720P (/dev/video2)
#   top:   USB 2.0 Camera (/dev/video0)
#
# 사용 예:
#   ./scripts/record.sh
#   SINGLE_TASK="큐브 잡아서 상자에 넣기" NUM_EPISODES=10 ./scripts/record.sh
#
# 환경변수:
#   SINGLE_TASK    태스크 설명 (비우면 실행 시 입력 프롬프트)
#   REPO_ID        데이터셋 repo_id (기본: ${HF_USER}/omx_record)
#   DATASET_ROOT   데이터 저장 경로. 비우면 ./data/<SINGLE_TASK> 사용
#   NUM_EPISODES   녹화할 에피소드 수 (기본: 5)
#   EPISODE_TIME_S 에피소드당 녹화 시간 (기본: 60)
#   RESET_TIME_S   에피소드 간 리셋 대기 시간 (기본: 10)
#   DISPLAY_DATA   화면에 카메라 표시 (기본: true)
#   PUSH_TO_HUB    녹화 후 Hub 업로드 (기본: false)
#
# 종료: Ctrl+C

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 로컬 환경 설정 자동 로드 (있으면)
[[ -f "$SCRIPT_DIR/_env.sh" ]] && source "$SCRIPT_DIR/_env.sh"

CAMERA_TOP_INDEX="${CAMERA_TOP_INDEX:-2}"
CAMERA_WRIST_INDEX="${CAMERA_WRIST_INDEX:-0}"
CAMERA_WIDTH="${CAMERA_WIDTH:-640}"
CAMERA_HEIGHT="${CAMERA_HEIGHT:-480}"
CAMERA_FPS="${CAMERA_FPS:-30}"

REPO_ID="${REPO_ID:-${HF_USER}/omx_record}"
SINGLE_TASK="${SINGLE_TASK:-}"
NUM_EPISODES="${NUM_EPISODES:-6}"
EPISODE_TIME_S="${EPISODE_TIME_S:-60}"
RESET_TIME_S="${RESET_TIME_S:-10}"
DISPLAY_DATA="${DISPLAY_DATA:-true}"
PUSH_TO_HUB="${PUSH_TO_HUB:-false}"

if [[ -z "$SINGLE_TASK" ]]; then
  echo -n "SINGLE_TASK (태스크 설명): "
  read -r SINGLE_TASK
  if [[ -z "$SINGLE_TASK" ]]; then
    echo "Error: SINGLE_TASK is required."
    exit 1
  fi
fi

# DATASET_ROOT 미지정 시 SINGLE_TASK 로 폴더명 생성 (공백·/·: → _)
if [[ -z "${DATASET_ROOT:-}" ]]; then
  TASK_DIR="${SINGLE_TASK// /_}"
  TASK_DIR="${TASK_DIR//\//_}"
  TASK_DIR="${TASK_DIR//:/_}"
  DATASET_ROOT="./data/${TASK_DIR}"
fi

CAM_BASE="width: ${CAMERA_WIDTH}, height: ${CAMERA_HEIGHT}, fps: ${CAMERA_FPS}"
CAMERAS_JSON="{ top: {type: hsv_opencv, index_or_path: ${CAMERA_TOP_INDEX}, ${CAM_BASE}}, wrist: {type: v4l2_opencv, index_or_path: ${CAMERA_WRIST_INDEX}, ${CAM_BASE}} }"

echo "=== LeRobot Record ==="
echo "Cameras: top=${CAMERA_TOP_INDEX}, wrist=${CAMERA_WRIST_INDEX} (${CAMERA_WIDTH}x${CAMERA_HEIGHT} @ ${CAMERA_FPS}fps)"
echo "Dataset: repo_id=${REPO_ID}  root=${DATASET_ROOT}  num_episodes=${NUM_EPISODES}"
echo "Task:    ${SINGLE_TASK}"
echo ""

python scripts/record.py \
    --robot.type=omx_follower \
    --robot.port="${OMX_FOLLOWER_PORT:-/dev/omx_follower}" \
    --robot.id=omx_follower_arm \
    --robot.cameras="${CAMERAS_JSON}" \
    --teleop.type=omx_leader \
    --teleop.port="${OMX_LEADER_PORT:-/dev/omx_leader}" \
    --teleop.id=omx_leader_arm \
    --display_data="${DISPLAY_DATA}" \
    --dataset.repo_id="${REPO_ID}" \
    --dataset.root="${DATASET_ROOT}" \
    --dataset.single_task="${SINGLE_TASK}" \
    --dataset.num_episodes="${NUM_EPISODES}" \
    --dataset.episode_time_s="${EPISODE_TIME_S}" \
    --dataset.reset_time_s="${RESET_TIME_S}" \
    --dataset.push_to_hub="${PUSH_TO_HUB}" \
    "$@"
