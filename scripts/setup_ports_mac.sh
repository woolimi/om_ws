#!/usr/bin/env bash
# Mac용 포트 매핑 — OMX leader/follower 장치를 시리얼 번호로 찾아 환경변수에 저장
#
# 사용법:
#   source ./scripts/setup_ports_mac.sh
#   # 이후 OMX_FOLLOWER_PORT, OMX_LEADER_PORT 환경변수 사용 가능
#
# record.sh 등에서 사용:
#   ./scripts/record.sh  # --robot.port 를 $OMX_FOLLOWER_PORT 로 쓰도록 수정 필요
#
# 최초 1회 — 각 장치의 시리얼 번호를 확인:
#   ioreg -p IOUSB -l | grep -E "USB Serial Number|USB Product Name"
# 또는:
#   system_profiler SPUSBDataType

# 사용자가 수정: 본인 장치의 시리얼 번호 넣기
FOLLOWER_SERIAL="${FOLLOWER_SERIAL:-}"   # 예: "FT1234AB"
LEADER_SERIAL="${LEADER_SERIAL:-}"       # 예: "FT5678CD"

# 장치 찾기 — ioreg에서 USB Serial Number로 매칭된 IOCalloutDevice 경로 반환
# (Mac의 usbmodem 이름은 USB hub 위치 기반이라 실제 시리얼과 일치하지 않을 수 있음)
find_device_by_serial() {
  local serial="$1"
  local cu
  cu=$(LC_ALL=C ioreg -p IOService -l -w0 2>/dev/null \
    | LC_ALL=C sed -n "/\"USB Serial Number\" = \"${serial}\"/,/\"IOCalloutDevice\"/p" \
    | LC_ALL=C grep -m1 '"IOCalloutDevice"' \
    | LC_ALL=C sed -E 's/.*"(\/dev\/[^"]+)".*/\1/')
  [[ -z "$cu" ]] && return 1
  # /dev/cu.* -> /dev/tty.*
  echo "${cu/cu./tty.}"
}

if [[ -z "$FOLLOWER_SERIAL" ]] || [[ -z "$LEADER_SERIAL" ]]; then
  echo "=== 연결된 USB 시리얼 장치 ==="
  ls /dev/tty.usbmodem* 2>/dev/null || echo "  (없음)"
  echo ""
  echo "=== USB 장치 (Product Name / Serial Number) ==="
  ioreg -p IOUSB -l 2>/dev/null | grep -E '"USB Product Name"|"USB Serial Number"' | head -20
  echo ""
  echo "위에서 follower/leader 의 시리얼 번호를 확인한 후"
  echo "  FOLLOWER_SERIAL=<번호> LEADER_SERIAL=<번호> source scripts/setup_ports_mac.sh"
  echo "으로 다시 실행하세요."
  return 1 2>/dev/null || exit 1
fi

OMX_FOLLOWER_PORT=$(find_device_by_serial "$FOLLOWER_SERIAL")
OMX_LEADER_PORT=$(find_device_by_serial "$LEADER_SERIAL")

# follower/leader 각각 독립적으로 처리 — 추론(inference)은 follower만 있어도 동작.
# 장치가 없으면 경고만 내고 진행 (스크립트 중단하지 않음).
if [[ -n "$OMX_FOLLOWER_PORT" ]]; then
  export OMX_FOLLOWER_PORT
else
  unset OMX_FOLLOWER_PORT
  echo "Warning: follower 장치 ($FOLLOWER_SERIAL) 를 찾을 수 없습니다. (연결 확인 필요)"
fi

if [[ -n "$OMX_LEADER_PORT" ]]; then
  export OMX_LEADER_PORT
else
  unset OMX_LEADER_PORT
  echo "Warning: leader 장치 ($LEADER_SERIAL) 를 찾을 수 없습니다. (teleop/record 시에만 필수)"
fi

echo "=== Mac 포트 매핑 완료 ==="
echo "OMX_FOLLOWER_PORT=${OMX_FOLLOWER_PORT:-(미연결)}"
echo "OMX_LEADER_PORT=${OMX_LEADER_PORT:-(미연결)}"
