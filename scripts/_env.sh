#!/usr/bin/env bash
# 로컬 머신 환경 설정 — teleop/record/inference 스크립트가 자동 source
# _env.sh 는 .gitignore 로 커밋되지 않음

# ── Mac 전용: Dynamixel USB 시리얼 (OpenRB-150) ─────────────
# Linux 에서는 무시됨 (아래 Darwin 가드로 동작 안 함)
# 시리얼 확인: ioreg -p IOUSB -l | grep -E "USB Serial Number|USB Product Name"
export FOLLOWER_SERIAL="<YOUR_FOLLOWER_SERIAL>"
export LEADER_SERIAL="<YOUR_LEADER_SERIAL>"

# ── OpenCV 카메라 인덱스 ───────────────────────────────────
# Linux 현재 값: top=USB 2.0 Camera(/dev/video2), wrist=Innomaker(/dev/video0)
export CAMERA_TOP_INDEX=2
export CAMERA_WRIST_INDEX=0

# ── 카메라 해상도/FPS ──────────────────────────────────────
export CAMERA_WIDTH=640
export CAMERA_HEIGHT=480
export CAMERA_FPS=30

# HSV 전처리 / v4l2 하드웨어 컨트롤은 scripts/hsv_camera.py 에서 관리.
# 카메라 연결 후 (V4L2OpenCVCamera/HsvOpenCVCamera.connect) 가 CAMERAS_JSON 의
# index_or_path 에 따라 올바른 /dev/video{N} 에 자동 적용하므로 USB 순서가 바뀌어도 OK.

# ── HuggingFace 사용자명 (업로드 기본 repo_id 에 사용) ──────
# export HF_USER=woolimi

# ── ACT 추론 파라미터 (inference.sh 전용) ──────────────────
# export N_ACTION_STEPS=30
# export TEMPORAL_ENSEMBLE_COEFF=0.01

# Mac 전용: 시리얼 → /dev/tty.usbmodem* 매핑 스크립트 자동 실행
if [[ "$(uname -s)" == "Darwin" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/setup_ports_mac.sh"
fi
