#!/usr/bin/env bash
# wrist: Innomaker-U20CAM-720P
# top: USB 2.0 Camera

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 로컬 환경 설정 자동 로드 (있으면)
[[ -f "$SCRIPT_DIR/_env.sh" ]] && source "$SCRIPT_DIR/_env.sh"

CAMERA_TOP_INDEX="${CAMERA_TOP_INDEX:-0}"
CAMERA_WRIST_INDEX="${CAMERA_WRIST_INDEX:-2}"
CAMERA_WIDTH="${CAMERA_WIDTH:-640}"
CAMERA_HEIGHT="${CAMERA_HEIGHT:-480}"
CAMERA_FPS="${CAMERA_FPS:-30}"

CAM_BASE="width: ${CAMERA_WIDTH}, height: ${CAMERA_HEIGHT}, fps: ${CAMERA_FPS}"
CAMERAS_JSON="{ top: {type: hsv_opencv, index_or_path: ${CAMERA_TOP_INDEX}, ${CAM_BASE}}, wrist: {type: v4l2_opencv, index_or_path: ${CAMERA_WRIST_INDEX}, ${CAM_BASE}} }"

python scripts/teleop.py \
  --robot.type=omx_follower \
  --robot.port="${OMX_FOLLOWER_PORT:-/dev/omx_follower}" \
  --robot.id=omx_follower_arm \
  --robot.cameras="${CAMERAS_JSON}" \
  --teleop.type=omx_leader \
  --teleop.port="${OMX_LEADER_PORT:-/dev/omx_leader}" \
  --teleop.id=omx_leader_arm \
  --display_data=true
