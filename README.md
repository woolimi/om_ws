# om_ws

OpenMANIPULATOR-X용 ROS2 워크스페이스 + LeRobot 모방학습 파이프라인.

## 설치

### 1. 리포 클론 (submodule 포함)

```bash
git clone --recurse-submodules git@github.com:woolimi/om_ws.git
cd om_ws

# 이미 클론했으면
git submodule update --init --recursive
```

### 2. Submodule 목록

- `src/DynamixelSDK`, `src/dynamixel_hardware_interface`, `src/dynamixel_interfaces`, `src/open_manipulator` — ROBOTIS 공식 패키지
- `src/lerobot` — HuggingFace LeRobot

### 3. Conda 환경 및 LeRobot editable 설치

```bash
conda activate lerobot
pip install -e src/lerobot
```

### 4. ROS2 빌드 (Linux 전용, ROS2 기능 사용 시에만)

```bash
colcon build --symlink-install
source install/setup.bash
```

> LeRobot 워크플로우(record/train/inference)만 쓰려면 colcon build 불필요.
> LeRobot은 자체적으로 시리얼 통신을 하므로 `src/lerobot` editable 설치만 있으면 충분합니다.

## 플랫폼별 설정

### Linux

- **포트**: udev rules로 `/dev/omx_follower`, `/dev/omx_leader` 심볼릭 링크 생성되어 있으면 바로 사용 가능
- **GPU**: CUDA 자동 감지 (`POLICY_DEVICE=cuda`)

### Mac

Mac은 udev가 없어 USB 포트 경로가 불안정합니다 (`/dev/tty.usbmodemXXX`). 시리얼 번호로 매핑하는 헬퍼 스크립트를 사용하세요.

**1. 시리얼 번호 확인 (최초 1회)**

```bash
source ./scripts/setup_ports_mac.sh
# → 연결된 장치 목록 + USB 시리얼 번호 출력
```

출력에서 follower / leader 장치의 **Serial Number** 값을 메모.

**2. 매핑**

```bash
FOLLOWER_SERIAL=<follower_시리얼> LEADER_SERIAL=<leader_시리얼> \
  source ./scripts/setup_ports_mac.sh
# → OMX_FOLLOWER_PORT, OMX_LEADER_PORT 환경변수 설정됨
```

**3. 영구 저장 (`~/.zshrc`)**

```bash
export FOLLOWER_SERIAL=FT1234AB
export LEADER_SERIAL=FT5678CD
source $HOME/om_ws/scripts/setup_ports_mac.sh
```

이후 `./scripts/teleop.sh`, `./scripts/record.sh`, `./scripts/inference.sh` 모두 정상 동작.

**Mac 주의사항:**
- **GPU**: Apple Silicon은 `POLICY_DEVICE=mps`, Intel Mac은 `cpu` (train.sh 자동 감지)
- **카메라 인덱스**: Linux와 다를 수 있음. `CAMERA_TOP_INDEX`, `CAMERA_WRIST_INDEX` 환경변수로 오버라이드
- **ROS2**: 공식 지원 안 됨. `src/` 안의 ROBOTIS 패키지는 빌드/사용 불가 (LeRobot 워크플로우만 가능)

## 워크플로우

```
teleop → record → (upload) → train → (upload_model) → inference
                ↑ merge (여러 데이터셋 합치기)
```

## 스크립트

### 데이터 수집

```bash
# 리더암 텔레옵 (로봇만 조작, 녹화 없음)
./scripts/teleop.sh

# 에피소드 녹화
SINGLE_TASK="Pick up Doll" NUM_EPISODES=10 ./scripts/record.sh
# → ./data/Pick_up_Doll/ 에 저장

# 여러 데이터셋 병합 (대화형)
./scripts/merge.sh
```

### 훈련

```bash
# 새 훈련 (ACT 정책, 데이터셋 선택 프롬프트)
./scripts/train.sh

# wandb 오프라인 로그 포함
WANDB_ENABLE=true ./scripts/train.sh

# 체크포인트에서 이어서 훈련
./scripts/train_resume.sh
```

### 추론

```bash
# 기본 추론 (모델/체크포인트 선택, 무한 반복, 녹화 없음)
./scripts/inference.sh

# ACT 파라미터 튜닝
N_ACTION_STEPS=30 ./scripts/inference.sh
TEMPORAL_ENSEMBLE_COEFF=0.01 ./scripts/inference.sh
```

## HuggingFace Hub 연동

### 초기 로그인 (최초 1회)

```bash
hf auth login
# → wandb.ai/authorize 에서 토큰 받아 붙여넣기
export HF_USER=<your_hf_username>  # ~/.zshrc 에 추가 권장
```

### 데이터셋

**업로드:**
```bash
./scripts/upload.sh
# → ./data/ 에서 선택 → hf.co/datasets/<user>/<name> 에 업로드
```

**다운로드:**
```bash
# 대화형
./scripts/download.sh

# 직접 지정
REPO_ID=woolimi/trainset ./scripts/download.sh
# → ./data/trainset/ 에 저장됨
```

### 모델

**업로드:**
```bash
# 대화형 (모델/체크포인트 선택)
./scripts/upload_model.sh

# 특정 체크포인트
CHECKPOINT=last ./scripts/upload_model.sh

# 런 전체 (모든 체크포인트 포함, 용량 큼)
INCLUDE_ALL=true ./scripts/upload_model.sh
```

**다운로드:**
```bash
# pretrained_model 폴더만 받기
hf download <user>/<model_name> --local-dir outputs/train/<model_name>/checkpoints/last/pretrained_model

# 예
hf download woolimi/act_trainset-last \
  --local-dir outputs/train/act_trainset/checkpoints/last/pretrained_model

# 이후 바로 추론 가능
POLICY_PATH=outputs/train/act_trainset/checkpoints/last/pretrained_model ./scripts/inference.sh
```

## 로컬 제외 폴더

다음은 `.gitignore`로 리포에서 제외되어 있습니다. 필요 시 HF에서 받아오세요:

- `data/` — 데이터셋 (`./scripts/download.sh`)
- `outputs/` — 훈련 결과/추론 임시 파일 (`hf download`)
- `wandb/` — 로컬 wandb 로그 (재훈련 시 재생성)
- `build/`, `install/`, `log/` — ROS2 빌드 산출물 (`colcon build`)

## 하드웨어

- **로봇:** OpenMANIPULATOR-X (Dynamixel XM430)
  - follower: `/dev/omx_follower`
  - leader: `/dev/omx_leader`
- **카메라:**
  - top: USB 2.0 Camera (`/dev/video2`, 인덱스 2)
  - wrist: Innomaker-U20CAM-720P (`/dev/video0`, 인덱스 0)
  - 해상도: 640×480 @ 30fps

USB 장치 번호가 바뀔 수 있으니 `v4l2-ctl --list-devices`로 확인.
