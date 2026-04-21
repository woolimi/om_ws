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

# 장치 찾기 — /dev/tty.usbmodem* 중 시리얼 번호 매칭
find_device_by_serial() {
  local serial="$1"
  for dev in /dev/tty.usbmodem*; do
    [[ ! -e "$dev" ]] && continue
    # Mac의 usbmodem 이름에 시리얼 일부가 포함됨
    if [[ "$dev" == *"$serial"* ]]; then
      echo "$dev"
      return 0
    fi
  done
  return 1
}

if [[ -z "$FOLLOWER_SERIAL" ]] || [[ -z "$LEADER_SERIAL" ]]; then
  echo "=== 연결된 USB 시리얼 장치 ==="
  ls /dev/tty.usbmodem* 2>/dev/null || echo "  (없음)"
  echo ""
  echo "=== 장치 상세 정보 ==="
  system_profiler SPUSBDataType 2>/dev/null | grep -E "Product ID|Serial Number|Location ID" | head -20
  echo ""
  echo "위에서 follower/leader 의 시리얼 번호를 확인한 후"
  echo "  FOLLOWER_SERIAL=<번호> LEADER_SERIAL=<번호> source scripts/setup_ports_mac.sh"
  echo "으로 다시 실행하세요."
  return 1 2>/dev/null || exit 1
fi

OMX_FOLLOWER_PORT=$(find_device_by_serial "$FOLLOWER_SERIAL")
OMX_LEADER_PORT=$(find_device_by_serial "$LEADER_SERIAL")

if [[ -z "$OMX_FOLLOWER_PORT" ]]; then
  echo "Error: follower 장치 ($FOLLOWER_SERIAL) 를 찾을 수 없습니다."
  return 1 2>/dev/null || exit 1
fi

if [[ -z "$OMX_LEADER_PORT" ]]; then
  echo "Error: leader 장치 ($LEADER_SERIAL) 를 찾을 수 없습니다."
  return 1 2>/dev/null || exit 1
fi

export OMX_FOLLOWER_PORT
export OMX_LEADER_PORT

echo "=== Mac 포트 매핑 완료 ==="
echo "OMX_FOLLOWER_PORT=$OMX_FOLLOWER_PORT"
echo "OMX_LEADER_PORT=$OMX_LEADER_PORT"
