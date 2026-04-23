#!/usr/bin/env bash
# LeRobot 추론 — outputs/train/ 훈련 모델로 로봇 제어 (녹화 없음, 무한 반복)
# scripts/infer.py 사용 (Ctrl+C 까지 policy 루프 반복)
#
# 사용법:
#   ./scripts/inference.sh
#   POLICY_PATH=outputs/train/act_v1 ./scripts/inference.sh
#
# 환경변수:
#   POLICY_PATH       모델 경로 (비우면 outputs/train/ 목록에서 선택)
#   SINGLE_TASK       태스크 설명 (비우면 입력 프롬프트)
#   EPISODE_TIME_S    한 루프 길이 (기본: 60). 루프 끝나면 즉시 다음 시작.
#   DISPLAY_DATA      화면에 카메라 표시 (기본: true)
#   RECORD_TOP_VIDEO  top 카메라 mp4 저장 (boolean, 기본: false)
#                     - true/1/yes: outputs/inference_videos/top_<timestamp>.mp4 자동 생성
#                     - false/0/no/빈 값: 비활성
#   CAMERA_TOP_INDEX / CAMERA_WRIST_INDEX / CAMERA_WIDTH / CAMERA_HEIGHT / CAMERA_FPS
#
# ACT 정책 추론 파라미터 (ACT 모델에만 적용):
#   N_ACTION_STEPS             정책이 예측한 chunk 중 실제 실행할 액션 수 (기본: 비설정 = 모델 기본값)
#                              - 작게(1~5): 매 step마다 재추론 → 반응 빠름, 느림
#                              - 크게(20~50): chunk를 길게 실행 → 빠름, 외란에 둔감
#                              - chunk_size 보다 클 수 없음 (chunk_size 는 훈련 시 고정)
#   TEMPORAL_ENSEMBLE_COEFF    시간적 앙상블 계수 (기본: 비설정)
#                              - 0에 가까우면 최신 예측 가중치 ↑
#                              - 1에 가까우면 과거 예측 평균 ↑ (부드럽지만 지연)
#                              - 예: 0.01 (ACT 논문 권장값)
#                              - 설정 시 n_action_steps=1 자동으로 강제됨
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
EPISODE_TIME_S="${EPISODE_TIME_S:-30}"
DISPLAY_DATA="${DISPLAY_DATA:-true}"
PLAY_SOUNDS="${PLAY_SOUNDS:-true}"
SINGLE_TASK="${SINGLE_TASK:-}"
RECORD_TOP_VIDEO="${RECORD_TOP_VIDEO:-false}"

# boolean → 타임스탬프 경로 자동 생성 (truthy 가 아니면 빈 문자열 = 비활성)
if [[ "${RECORD_TOP_VIDEO,,}" =~ ^(1|true|yes)$ ]]; then
  TOP_VIDEO_PATH="outputs/inference_videos/top_$(date +%Y%m%d_%H%M%S).mp4"
else
  TOP_VIDEO_PATH=""
fi

if [[ "$(uname -s)" == "Linux" ]]; then
  POLICY_DEVICE="${POLICY_DEVICE:-cuda}"
else
  POLICY_DEVICE="${POLICY_DEVICE:-mps}"
fi

# ACT 추론 파라미터
# n_action_steps=20: chunk 중 20 step 실행 후 재추론 (반응성과 속도 균형)
# temporal_ensemble_coeff 는 비워둠 (설정 시 n_action_steps=1 강제되어 매 step 재추론)
N_ACTION_STEPS="${N_ACTION_STEPS:-100}"
TEMPORAL_ENSEMBLE_COEFF="${TEMPORAL_ENSEMBLE_COEFF:-}"

TRAIN_DIR="outputs/train"
if [[ -z "${POLICY_PATH:-}" ]]; then
  if [[ ! -d "$TRAIN_DIR" ]]; then
    echo "Error: $TRAIN_DIR not found. 먼저 train.sh로 훈련하거나 POLICY_PATH를 지정하세요."
    exit 1
  fi
  RUNS=()
  for d in "$TRAIN_DIR"/*/; do
    [[ -d "$d" ]] && RUNS+=("${d%/}")
  done
  if [[ ${#RUNS[@]} -eq 0 ]]; then
    echo "Error: $TRAIN_DIR에 모델이 없습니다."
    exit 1
  fi
  echo "=== $TRAIN_DIR 모델 목록 ==="
  for i in "${!RUNS[@]}"; do
    echo "  $((i + 1))) $(basename "${RUNS[$i]}")"
  done
  echo ""
  echo -n "모델 번호: "
  read -r CHOICE
  if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [[ "$CHOICE" -lt 1 ]] || [[ "$CHOICE" -gt ${#RUNS[@]} ]]; then
    echo "Error: 잘못된 선택입니다."
    exit 1
  fi
  POLICY_PATH="${RUNS[$((CHOICE - 1))]}"
  echo "선택: $POLICY_PATH"
  echo ""
fi

# 체크포인트 선택 (POLICY_PATH가 훈련 디렉토리인 경우)
if [[ -d "$POLICY_PATH" ]]; then
  if [[ -d "${POLICY_PATH}/checkpoints" ]]; then
    CHECKPOINTS=()
    for d in "${POLICY_PATH}/checkpoints"/*/; do
      [[ -d "${d}pretrained_model" ]] && CHECKPOINTS+=("$(basename "$d")")
    done
    CHECKPOINTS=($(printf '%s\n' "${CHECKPOINTS[@]}" | sort -n))
    if [[ ${#CHECKPOINTS[@]} -eq 0 ]]; then
      echo "Error: ${POLICY_PATH}/checkpoints/ 아래에 pretrained_model이 없습니다."
      exit 1
    fi
    if [[ ${#CHECKPOINTS[@]} -eq 1 ]]; then
      POLICY_PATH="${POLICY_PATH}/checkpoints/${CHECKPOINTS[0]}/pretrained_model"
      echo "Checkpoint: ${CHECKPOINTS[0]} (유일)"
    else
      echo "=== 체크포인트 선택 ==="
      for i in "${!CHECKPOINTS[@]}"; do
        echo "  $((i + 1))) ${CHECKPOINTS[$i]}"
      done
      echo ""
      echo -n "번호 (기본=마지막): "
      read -r CP_CHOICE
      if [[ -z "$CP_CHOICE" ]]; then
        CP_CHOICE=${#CHECKPOINTS[@]}
      fi
      if ! [[ "$CP_CHOICE" =~ ^[0-9]+$ ]] || [[ "$CP_CHOICE" -lt 1 ]] || [[ "$CP_CHOICE" -gt ${#CHECKPOINTS[@]} ]]; then
        echo "Error: 잘못된 선택입니다."
        exit 1
      fi
      POLICY_PATH="${POLICY_PATH}/checkpoints/${CHECKPOINTS[$((CP_CHOICE - 1))]}/pretrained_model"
      echo "선택: $(basename "$(dirname "$POLICY_PATH")")"
    fi
    echo ""
  elif [[ ! -f "${POLICY_PATH}/config.json" ]]; then
    echo "Error: $POLICY_PATH 는 체크포인트 폴더가 아닙니다 (config.json 없음)."
    exit 1
  fi
else
  echo "Error: POLICY_PATH not found: $POLICY_PATH"
  exit 1
fi

if [[ -z "$SINGLE_TASK" ]]; then
  echo -n "SINGLE_TASK (태스크 설명): "
  read -r SINGLE_TASK
  SINGLE_TASK="${SINGLE_TASK:-Policy inference}"
fi

CAM_BASE="width: ${CAMERA_WIDTH}, height: ${CAMERA_HEIGHT}, fps: ${CAMERA_FPS}"
CAMERAS_JSON="{ top: {type: hsv_opencv, index_or_path: ${CAMERA_TOP_INDEX}, ${CAM_BASE}}, wrist: {type: v4l2_opencv, index_or_path: ${CAMERA_WRIST_INDEX}, ${CAM_BASE}} }"

POLICY_ARGS=(--policy.device="${POLICY_DEVICE}")
[[ -n "$N_ACTION_STEPS" ]] && POLICY_ARGS+=(--policy.n_action_steps="${N_ACTION_STEPS}")
[[ -n "$TEMPORAL_ENSEMBLE_COEFF" ]] && POLICY_ARGS+=(--policy.temporal_ensemble_coeff="${TEMPORAL_ENSEMBLE_COEFF}")

RECORD_ARGS=()
[[ -n "$TOP_VIDEO_PATH" ]] && RECORD_ARGS+=(--record_top_video_path="${TOP_VIDEO_PATH}")

echo "=== LeRobot Inference (Ctrl+C to stop) ==="
echo "Policy:   $POLICY_PATH"
echo "Device:   ${POLICY_DEVICE}"
echo "Cameras:  top=${CAMERA_TOP_INDEX}, wrist=${CAMERA_WRIST_INDEX} (${CAMERA_WIDTH}x${CAMERA_HEIGHT} @ ${CAMERA_FPS}fps)"
echo "Episode:  ${EPISODE_TIME_S}s"
echo "Task:     ${SINGLE_TASK}"
[[ -n "$N_ACTION_STEPS" ]] && echo "n_action_steps: ${N_ACTION_STEPS}"
[[ -n "$TEMPORAL_ENSEMBLE_COEFF" ]] && echo "temporal_ensemble_coeff: ${TEMPORAL_ENSEMBLE_COEFF}"
[[ -n "$TOP_VIDEO_PATH" ]] && echo "Recording: ${TOP_VIDEO_PATH}"
echo ""

python scripts/infer.py \
  --robot.type=omx_follower \
  --robot.port="${OMX_FOLLOWER_PORT:-/dev/omx_follower}" \
  --robot.id=omx_follower_arm \
  --robot.cameras="${CAMERAS_JSON}" \
  --policy.path="${POLICY_PATH}" \
  "${POLICY_ARGS[@]}" \
  "${RECORD_ARGS[@]}" \
  --single_task="${SINGLE_TASK}" \
  --fps="${CAMERA_FPS}" \
  --episode_time_s="${EPISODE_TIME_S}" \
  --display_data="${DISPLAY_DATA}" \
  --play_sounds="${PLAY_SOUNDS}" \
  "$@"
