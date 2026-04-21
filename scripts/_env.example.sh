#!/usr/bin/env bash
# 템플릿: `cp scripts/_env.example.sh scripts/_env.sh` 로 복사한 뒤 본인 값으로 수정.
# teleop/record/inference 스크립트가 자동으로 _env.sh 를 source 합니다.
# _env.sh 는 .gitignore 로 커밋되지 않습니다.

# ── Mac: Dynamixel USB 시리얼 (OpenRB-150) ─────────────────
# 시리얼 확인: ioreg -p IOUSB -l | grep -E "USB Serial Number|USB Product Name"
export FOLLOWER_SERIAL="<YOUR_FOLLOWER_SERIAL>"
export LEADER_SERIAL="<YOUR_LEADER_SERIAL>"

# ── OpenCV 카메라 인덱스 ───────────────────────────────────
# Linux 기본: top=2, wrist=0 (udev rules)
# Mac: 연결 순서에 따라 다름 — lerobot-find-cameras opencv 로 확인
export CAMERA_TOP_INDEX=0
export CAMERA_WRIST_INDEX=2

# Mac 전용: 시리얼 → /dev/tty.usbmodem* 매핑 스크립트 자동 실행
if [[ "$(uname -s)" == "Darwin" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/setup_ports_mac.sh"
fi
