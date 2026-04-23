"""HSV 전처리 파라미터 실시간 튜닝 도구.

scripts/hsv_camera.py 의 HsvOpenCVCameraConfig 기본값 (HSV + v4l2 controls) 을
그대로 불러와 적용하므로, 시작 화면이 추론 시 실제 보이는 화면과 동일.
trackbar 로 조정하며 before/after 를 나란히 비교.

사용:
  python scripts/tune_hsv.py                 # 기본 /dev/video2
  CAMERA_INDEX=0 python scripts/tune_hsv.py  # 다른 카메라
  CAMERA_WIDTH=640 CAMERA_HEIGHT=480 CAMERA_FPS=30 python scripts/tune_hsv.py

조작:
  - HSV trackbar: 실시간 반영
  - v4l2 trackbar (exposure/saturation/WB): 변경 시 v4l2-ctl 재적용
  - 'p': 현재 값 콘솔 출력
  - 'q' 또는 ESC: 종료 (마지막 값 자동 출력)
"""

import os
import subprocess
import sys

import cv2
import numpy as np

# hsv_camera.py 의 기본값을 소스 오브 트루스로 사용
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hsv_camera import HsvOpenCVCameraConfig  # noqa: E402


def apply_hsv(image_bgr, v_gamma, clahe_clip_limit, clahe_tile_grid_size, s_scale):
    """scripts/hsv_camera.py 의 _postprocess_image 와 동일 로직."""
    hsv = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2HSV)
    h_ch, s_ch, v_ch = cv2.split(hsv)

    if v_gamma != 1.0:
        lut = np.array(
            [((i / 255.0) ** v_gamma) * 255.0 for i in range(256)]
        ).astype(np.uint8)
        v_ch = cv2.LUT(v_ch, lut)

    if clahe_clip_limit > 0:
        clahe = cv2.createCLAHE(
            clipLimit=clahe_clip_limit,
            tileGridSize=(clahe_tile_grid_size, clahe_tile_grid_size),
        )
        v_ch = clahe.apply(v_ch)

    if s_scale != 1.0:
        s_ch = np.clip(s_ch.astype(np.float32) * s_scale, 0, 255).astype(np.uint8)

    return cv2.cvtColor(cv2.merge([h_ch, s_ch, v_ch]), cv2.COLOR_HSV2BGR)


def apply_v4l2(device, controls):
    """v4l2-ctl 로 컨트롤 적용. 실패해도 조용히 넘어감."""
    if sys.platform != "linux" or not controls:
        return
    cmd = ["v4l2-ctl", "-d", device]
    for key, value in controls.items():
        cmd.append(f"--set-ctrl={key}={value}")
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        pass


def main():
    # hsv_camera.py 의 기본값 로드
    defaults = HsvOpenCVCameraConfig(index_or_path=0)  # index_or_path 는 dummy

    index = int(os.environ.get("CAMERA_INDEX", os.environ.get("CAMERA_TOP_INDEX", 2)))
    width = int(os.environ.get("CAMERA_WIDTH", 640))
    height = int(os.environ.get("CAMERA_HEIGHT", 480))
    fps = int(os.environ.get("CAMERA_FPS", 30))
    device = f"/dev/video{index}"

    cap = cv2.VideoCapture(index)
    if not cap.isOpened():
        print(f"ERROR: cannot open camera index {index}", file=sys.stderr)
        sys.exit(1)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)

    # hsv_camera.py 의 connect() 와 동일하게 v4l2 컨트롤 적용
    current_v4l2 = dict(defaults.v4l2_controls)
    apply_v4l2(device, current_v4l2)

    win = "HSV tune (left: raw | right: processed)"
    cv2.namedWindow(win, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win, width * 2, height)

    # HSV trackbar (실수는 *N 스케일)
    cv2.createTrackbar("v_gamma x100", win, int(defaults.v_gamma * 100), 500, lambda _: None)
    cv2.createTrackbar("clahe_clip x10", win, int(max(defaults.clahe_clip_limit, 0) * 10), 100, lambda _: None)
    cv2.createTrackbar("clahe_tile", win, int(defaults.clahe_tile_grid_size), 32, lambda _: None)
    cv2.createTrackbar("s_scale x100", win, int(defaults.s_scale * 100), 500, lambda _: None)

    # v4l2 trackbar — 변경 시 콜백에서 v4l2-ctl 재적용
    def on_v4l2_change(_):
        current_v4l2["white_balance_temperature"] = max(cv2.getTrackbarPos("wb_temp", win), 2000)
        current_v4l2["exposure_time_absolute"] = max(cv2.getTrackbarPos("exposure", win), 1)
        current_v4l2["saturation"] = cv2.getTrackbarPos("hw_saturation", win)
        apply_v4l2(device, current_v4l2)

    cv2.createTrackbar("wb_temp", win, int(current_v4l2.get("white_balance_temperature", 5000)), 7500, on_v4l2_change)
    cv2.createTrackbar("exposure", win, int(current_v4l2.get("exposure_time_absolute", 80)), 500, on_v4l2_change)
    cv2.createTrackbar("hw_saturation", win, int(current_v4l2.get("saturation", 255)), 255, on_v4l2_change)

    def read_hsv_params():
        v_gamma = max(cv2.getTrackbarPos("v_gamma x100", win), 1) / 100.0
        clahe_clip = cv2.getTrackbarPos("clahe_clip x10", win) / 10.0
        clahe_tile = max(cv2.getTrackbarPos("clahe_tile", win), 2)
        s_scale = max(cv2.getTrackbarPos("s_scale x100", win), 1) / 100.0
        return v_gamma, clahe_clip, clahe_tile, s_scale

    def print_values(hsv_params):
        v_gamma, clahe_clip, clahe_tile, s_scale = hsv_params
        print("─" * 60)
        print("paste into scripts/hsv_camera.py HsvOpenCVCameraConfig:")
        print(f"    v_gamma: float = {v_gamma}")
        print(f"    clahe_clip_limit: float = {clahe_clip}")
        print(f"    clahe_tile_grid_size: int = {clahe_tile}")
        print(f"    s_scale: float = {s_scale}")
        print("    v4l2_controls: dict[str, int] = field(default_factory=lambda: {")
        for k, v in current_v4l2.items():
            print(f'        "{k}": {v},')
        print("    })")
        print("─" * 60)

    hsv_params = read_hsv_params()
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue
            hsv_params = read_hsv_params()
            processed = apply_hsv(frame, *hsv_params)

            label = (
                f"g={hsv_params[0]:.2f} clahe={hsv_params[1]:.1f}/{hsv_params[2]} "
                f"s={hsv_params[3]:.2f} | exp={current_v4l2['exposure_time_absolute']} "
                f"wb={current_v4l2['white_balance_temperature']}"
            )
            cv2.putText(
                processed, label, (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.5,
                (0, 255, 255), 2, cv2.LINE_AA,
            )

            combined = np.hstack([frame, processed])
            cv2.imshow(win, combined)

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("p"):
                print_values(hsv_params)
    finally:
        print_values(hsv_params)
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
