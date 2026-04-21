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
V_GAMMA="${V_GAMMA:-1.0}"
CLAHE_CLIP_LIMIT="${CLAHE_CLIP_LIMIT:-2.0}"
CLAHE_TILE_GRID_SIZE="${CLAHE_TILE_GRID_SIZE:-8}"
S_SCALE="${S_SCALE:-1.0}"

CAM_BASE="width: ${CAMERA_WIDTH}, height: ${CAMERA_HEIGHT}, fps: ${CAMERA_FPS}"
HSV_EXTRA="v_gamma: ${V_GAMMA}, clahe_clip_limit: ${CLAHE_CLIP_LIMIT}, clahe_tile_grid_size: ${CLAHE_TILE_GRID_SIZE}, s_scale: ${S_SCALE}"
CAMERAS_JSON="{ top: {type: hsv_opencv, index_or_path: ${CAMERA_TOP_INDEX}, ${CAM_BASE}, ${HSV_EXTRA}}, wrist: {type: opencv, index_or_path: ${CAMERA_WRIST_INDEX}, ${CAM_BASE}} }"

python scripts/teleop.py \
  --robot.type=omx_follower \
  --robot.port="${OMX_FOLLOWER_PORT:-/dev/omx_follower}" \
  --robot.id=omx_follower_arm \
  --robot.cameras="${CAMERAS_JSON}" \
  --teleop.type=omx_leader \
  --teleop.port="${OMX_LEADER_PORT:-/dev/omx_leader}" \
  --teleop.id=omx_leader_arm \
  --display_data=true
