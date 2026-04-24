#!/usr/bin/env bash
# 카메라 설정(경로/해상도/FPS/HSV/v4l2) 은 scripts/config.json 에서 관리.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR/.."

# 로컬 환경 설정 자동 로드 (있으면)
[[ -f "$SCRIPT_DIR/_env.sh" ]] && source "$SCRIPT_DIR/_env.sh"

CAMERAS_JSON=$(python3 "$SCRIPT_DIR/_cameras.py") || exit 1

python scripts/teleop.py \
  --robot.type=omx_follower \
  --robot.port="${OMX_FOLLOWER_PORT:-/dev/omx_follower}" \
  --robot.id=omx_follower_arm \
  --robot.cameras="${CAMERAS_JSON}" \
  --teleop.type=omx_leader \
  --teleop.port="${OMX_LEADER_PORT:-/dev/omx_leader}" \
  --teleop.id=omx_leader_arm \
  --display_data=true
