#!/usr/bin/env bash
# 로컬 머신 환경 설정 — teleop/record/inference 스크립트가 자동 source
#
# 카메라 설정(인덱스/경로/해상도/FPS/HSV/v4l2) 은 모두 scripts/config.json 에서
# 관리하며, shell 쪽은 scripts/_cameras.py 헬퍼로 직접 읽는다.
# 여기는 config.json 에 담기 부적합한 머신별 설정(시리얼, HF_USER 등)만.

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
