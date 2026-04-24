This file provides guidance to AI agents when working with code in this repository.

## Project Overview

OpenMANIPULATOR-X(OMX) 로봇 팔 워크스페이스. ROS2 + HuggingFace LeRobot(ACT 정책) 모방학습 파이프라인을 함께 담고 있다. 주된 용도는 **LeRobot 기반 데이터 수집 → 훈련 → 추론** 흐름이며, ROS2 패키지는 선택적이다(MoveIt 등 다른 제어를 쓸 때만 필요).

## Tech Stack

Python 3.12 (conda env `lerobot`) · PyTorch (CUDA/MPS/CPU) · LeRobot (editable submodule) · OpenCV · ROS2 (선택) · draccus(CLI) · HuggingFace Hub

## Repository Structure

```
om_ws/
├── scripts/            ← 사용자 진입점 (모든 워크플로우가 여기서 시작)
│   ├── record.sh       녹화 (리더 텔레옵 + 정책 없음)
│   ├── teleop.sh       녹화 없이 리더로 조작만
│   ├── train.sh        ACT 훈련
│   ├── train_resume.sh 체크포인트 이어서 훈련
│   ├── inference.sh    추론 (녹화 없음, 무한 루프)
│   ├── merge.sh        여러 데이터셋 병합
│   ├── upload.sh       데이터셋 HF 업로드
│   ├── upload_model.sh 모델 HF 업로드
│   ├── download.sh     HF에서 데이터셋 받기
│   ├── setup_ports_mac.sh  Mac USB 시리얼 매핑
│   ├── record.py       lerobot-record 래퍼 (hsv_opencv 등록용)
│   ├── infer.py        커스텀 추론 스크립트 (녹화 없이 무한)
│   ├── hsv_camera.py   HSV V채널 CLAHE 평준화 OpenCV 카메라
│   └── merge_datasets_local.py  데이터셋 병합 Python
├── src/                ← 외부 submodule (ROS2 패키지 + lerobot)
│   ├── lerobot/        HuggingFace LeRobot (editable 설치)
│   ├── DynamixelSDK/
│   ├── dynamixel_hardware_interface/
│   ├── dynamixel_interfaces/
│   └── open_manipulator/
├── data/               ← (gitignored) 녹화된 LeRobot 데이터셋
├── outputs/            ← (gitignored) 훈련 결과·추론 임시 파일
├── wandb/              ← (gitignored) wandb 오프라인 로그
├── build/ install/ log/ ← (gitignored) colcon 산출물
├── README.md           사용자용 설치·사용 가이드
└── .gitignore
```

## Key Architectural Facts

### LeRobot은 editable 모드로 설치되어 있다

`src/lerobot`이 submodule이지만 **동시에 pip editable 설치**되어 있어 `/home/woolimi/miniforge3/envs/lerobot/lib/python3.12/site-packages/__editable__.lerobot-0.5.2.pth`가 `src/lerobot/src`를 가리킨다. 즉 **submodule 파일을 수정하면 바로 반영**된다. 하지만 upstream 변경을 깨끗하게 받으려면 submodule은 건드리지 않는 게 원칙.

### 커스텀 확장은 submodule 밖에서

- **추론 스크립트**: `src/lerobot/`에 두지 않고 `scripts/infer.py`로 분리. `lerobot.scripts.lerobot_record`의 `record_loop`를 재사용하되, `save_episode()`를 호출하지 않아 녹화 없이 무한 반복.
- **커스텀 카메라**: `scripts/hsv_camera.py`가 `@CameraConfig.register_subclass("hsv_opencv")`로 등록. `scripts/record.py`는 `lerobot-record`를 호출하기 전에 이 모듈을 import하는 얇은 래퍼.
- 이렇게 하면 upstream lerobot을 전혀 수정하지 않고도 커스텀이 가능.

### HSV V 채널 CLAHE 평준화

`scripts/hsv_camera.py`의 `HsvOpenCVCamera`는 `OpenCVCamera`를 상속해서 `_postprocess_image()`에서 BGR→HSV→V채널 CLAHE→HSV→BGR로 변환. **조명 변화로 색이 구분 안 되는 문제**를 완화하기 위함. record.sh/inference.sh는 `type: hsv_opencv`를 사용하며, teleop.sh는 학습 데이터 생성과 무관하므로 평준화 미적용. **훈련과 추론은 같은 `clahe_clip_limit`을 사용해야 일관성 유지**.

### 포트 매핑

- **Linux**: udev rules로 `/dev/omx_follower`, `/dev/omx_leader` symlink를 만들어놓고 스크립트에서 기본값으로 사용.
- **Mac**: udev가 없어 `scripts/setup_ports_mac.sh`가 `ioreg`로 USB Serial Number 매칭해 `OMX_FOLLOWER_PORT`, `OMX_LEADER_PORT` 환경변수를 설정. 스크립트들은 `${OMX_FOLLOWER_PORT:-/dev/omx_follower}` 형태로 둘 다 지원.

### scripts/config.json — 카메라 설정 단일 출처 (Single Source of Truth)

카메라 경로(by-id), 해상도/FPS, HSV 전처리 파라미터, v4l2 하드웨어 컨트롤 등 모든 카메라 관련 설정을 `scripts/config.json`에 통합. **환경변수 인젝션 없이** Python과 shell이 이 파일을 직접 읽는다.

- **Python 쪽 (`hsv_camera.py`, `tune_hsv.py`)**: `hsv_camera.load_config()` / `save_config()` 직접 호출.
- **Shell 쪽 (`record.sh`/`inference.sh`/`teleop.sh`)**: `scripts/_cameras.py` 헬퍼 호출로 `--robot.cameras` 에 넘길 flow-YAML 문자열을 얻음.
  - `CAMERAS_JSON=$(python3 scripts/_cameras.py)` — 전체 cameras 설정
  - `python3 scripts/_cameras.py --key camera_fps` — 개별 값 (inference.sh 의 `--fps`)
- **카메라 경로**: `/dev/v4l/by-id/...` 로 고정. USB 포트가 재열거돼도 같은 물리 카메라에 `top`/`wrist` 역할이 유지됨.

### scripts/_env.sh

record.sh/teleop.sh/inference.sh 시작 시 자동 source. 카메라 설정은 `config.json`에서 직접 읽으므로 여기는 머신별 설정(Dynamixel 시리얼, `HF_USER`, Mac `setup_ports_mac.sh` 호출) 전용.

## Data Flow

```
teleop.sh ─(리허설)
             │
record.sh ──→ data/<task>/      (HSV 평준화 후 저장)
             │
             ▼
            merge.sh ─→ data/<merged>/  (선택적)
             │
             ▼
           train.sh ─→ outputs/train/<model>/checkpoints/<step>/pretrained_model/
             │
             ├─→ upload_model.sh ─→ hf.co/models/<user>/<name>
             │
             ▼
        inference.sh ─→ /dev/shm/lerobot_infer (RAM, 즉시 삭제)
```

Hub 왕복: `upload.sh`/`upload_model.sh`로 올리고, `download.sh`/`hf download`로 받음.

## Running Commands

**CRITICAL**: conda 환경 활성화가 선행되어야 함.
```bash
conda activate lerobot
```

- **CLI 실행**: 스크립트들이 `cd "$SCRIPT_DIR/.."`로 리포 루트 이동 후 실행. 어느 디렉토리에서 호출해도 OK.
- **Python 실행**: `python scripts/infer.py` 또는 `python scripts/record.py`. `scripts/` 디렉토리가 자동으로 `sys.path`에 들어가서 `import hsv_camera`가 작동.
- **LeRobot CLI 엔트리포인트 (`lerobot-record`, `lerobot-train` 등)** 는 `src/lerobot/pyproject.toml [project.scripts]`에 등록. conda env 활성화 시 바로 사용 가능.

## Gotchas & Non-Obvious Behaviors

- **`lerobot-record`는 항상 디스크에 녹화**한다. 녹화 없는 추론이 필요하면 `scripts/infer.py` 사용.
- **`record_loop`에서 "No policy or teleoperator provided" 경고**가 뜨면 에피소드 간 리셋 구간을 의미. 추론 시에는 `RESET_TIME_S=0`이 기본값이라 이 경고가 안 나와야 한다.
- **`n_action_steps=30`이 inference.sh 기본값**. ACT는 매 청크마다 inference → 청크 내 n개 스텝만 실행 후 재추론. 30은 반응성/속도 trade-off의 중간값. 떨림이 심하면 `TEMPORAL_ENSEMBLE_COEFF=0.01`로 바꿀 수 있고, 이 경우 n_action_steps=1이 강제됨.
- **USB 2.0 대역폭 공유 문제**: 카메라 2개 + 로봇 2개가 같은 USB 2.0 버스에 있으면 220Mbps+ 소모로 시리얼 통신 지연 → 로봇 떨림 발생. `lsusb -t`로 확인하고 USB 3.0 포트에 분산.
- **`WANDB_ENABLE=false`가 train.sh 기본값**. wandb 로그인 프롬프트를 피하기 위함. 로컬 로그가 필요하면 `WANDB_ENABLE=true WANDB_MODE=offline` (모드는 이미 offline 기본).
- **wandb local (self-hosted)**은 2024년부터 라이선스 필요. `wandb.ai` 무료 계정 + offline → sync 방식을 권장.
- **`HF_USER` 환경변수** 가 스크립트 여러 곳에서 기본값 생성에 쓰임 (`${HF_USER}/omx_record` 등). `~/.zshrc`에 설정 권장.
- **추론 시 `/dev/shm/lerobot_infer`**: 디스크 I/O 0. Mac에선 tmpfs가 없어 infer.py가 자동으로 tempdir로 fallback.
- **`hf` CLI**: 예전 `huggingface-cli`는 deprecated. 모든 스크립트는 `hf upload/download`를 사용.

## Common Tasks

**새 카메라 전처리 로직 추가하기:**
1. `scripts/hsv_camera.py`를 참고해 `OpenCVCamera` 상속 + `_postprocess_image` 오버라이드
2. `@CameraConfig.register_subclass("my_type")` 데코레이터로 등록
3. `scripts/record.py`/`scripts/infer.py`에서 import 추가 (또는 자동 등록되는 모듈에 import 구문 넣기)
4. record.sh/inference.sh의 `CAMERAS_JSON`에서 `type: my_type` 사용

**훈련 파이프라인 조정하기:**
- `train.sh`는 환경변수로 `STEPS`, `BATCH_SIZE`, `NUM_WORKERS`, `SAVE_FREQ` 등 제어. 기본값들이 상단 변수 섹션에 있다.

**추론 성능 튜닝:**
- 떨림 해결: `TEMPORAL_ENSEMBLE_COEFF=0.01` 또는 `N_ACTION_STEPS` 감소
- 느린 루프: 카메라 해상도 감소 (`CAMERA_WIDTH`, `CAMERA_HEIGHT`) 또는 `CAMERA_FPS` 감소
- GPU는 `POLICY_DEVICE=cuda` (Linux)/`mps` (Apple Silicon)/`cpu`로 강제 가능

## External References

- `src/lerobot/CLAUDE.md` — LeRobot 내부 구조 가이드 (submodule에 포함됨)
- `README.md` — 사용자용 설치·사용 가이드
