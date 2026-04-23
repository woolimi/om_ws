#!/usr/bin/env bash
# 로컬 머신 환경 설정 — teleop/record/inference 스크립트가 자동 source
# _env.sh 는 .gitignore 로 커밋되지 않음

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CONFIG_JSON="$_SCRIPT_DIR/config.json"

# ── config.json 에서 카메라 설정 로드 ─────────────────────────
# 환경변수가 이미 설정되어 있으면 config.json 값을 덮어쓰지 않음
if [[ -f "$_CONFIG_JSON" ]]; then
  eval "$(python3 -c "
import json, os, sys
try:
    with open('$_CONFIG_JSON') as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)
keys = [
    'camera_top_index', 'camera_wrist_index',
    'camera_width', 'camera_height', 'camera_fps',
]
for k in keys:
    env_key = k.upper()
    if env_key not in os.environ and k in cfg:
        print(f'export {env_key}={cfg[k]}')
")"
fi

# ── Mac 전용: Dynamixel USB 시리얼 (OpenRB-150) ─────────────
# Linux 에서는 무시됨 (아래 Darwin 가드로 동작 안 함)
# 시리얼 확인: ioreg -p IOUSB -l | grep -E "USB Serial Number|USB Product Name"
export FOLLOWER_SERIAL="${FOLLOWER_SERIAL:-<YOUR_FOLLOWER_SERIAL>}"
export LEADER_SERIAL="${LEADER_SERIAL:-<YOUR_LEADER_SERIAL>}"

# ── HuggingFace 사용자명 (업로드 기본 repo_id 에 사용) ──────
# export HF_USER=woolimi

# ── ACT 추론 파라미터 (inference.sh 전용) ──────────────────
# export N_ACTION_STEPS=30
# export TEMPORAL_ENSEMBLE_COEFF=0.01

# Mac 전용: 시리얼 → /dev/tty.usbmodem* 매핑 스크립트 자동 실행
if [[ "$(uname -s)" == "Darwin" ]]; then
  source "$_SCRIPT_DIR/setup_ports_mac.sh"
fi
