"""Extended OpenCV cameras with v4l2 control and HSV post-processing.

두 개의 카메라 타입을 제공:
- `v4l2_opencv`: OpenCVCamera + connect() 이후 v4l2-ctl 자동 적용. HSV 후처리 없음.
- `hsv_opencv`: v4l2_opencv + BGR→HSV gamma/CLAHE/saturation 후처리.

OpenCV 의 VideoCapture 가 카메라를 열 때 일부 드라이버에서 v4l2 컨트롤이
기본값으로 리셋되는 문제를 해결하기 위해, 오픈 직후 다시 설정한다.

사용:
  --robot.cameras="{
    top: {type: hsv_opencv, index_or_path: 2, width: 640, height: 480, fps: 30},
    wrist: {type: v4l2_opencv, index_or_path: 0, width: 640, height: 480, fps: 30}
  }"
"""

import logging
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Any

import cv2
import numpy as np
from numpy.typing import NDArray

from lerobot.cameras.configs import CameraConfig, ColorMode
from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig


def _apply_v4l2_controls(device: str, controls: dict[str, int]) -> None:
    """v4l2-ctl 로 컨트롤 적용. Linux + v4l2-ctl 있는 경우만. 실패해도 조용히 warning만."""
    if sys.platform != "linux" or not controls:
        return
    cmd = ["v4l2-ctl", "-d", device]
    for key, value in controls.items():
        cmd.append(f"--set-ctrl={key}={value}")
    try:
        result = subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        logging.warning("v4l2-ctl not found; skipping v4l2 controls for %s", device)
        return
    if result.returncode != 0:
        logging.warning("v4l2-ctl failed for %s: %s", device, result.stderr.strip())
    else:
        logging.info("Applied v4l2 controls to %s: %s", device, controls)


@CameraConfig.register_subclass("v4l2_opencv")
@dataclass
class V4L2OpenCVCameraConfig(OpenCVCameraConfig):
    """OpenCVCameraConfig + connect() 이후 v4l2-ctl 자동 적용.

    기본값은 wrist 카메라(Innomaker) 용 "자동(기본값) 복구" 프리셋.
    """

    v4l2_controls: dict[str, int] = field(
        default_factory=lambda: {
            "white_balance_automatic": 1,
            "auto_exposure": 3,
            "saturation": 64,
            "brightness": 0,
            "contrast": 32,
            "gamma": 100,
            "hue": 0,
        }
    )


class V4L2OpenCVCamera(OpenCVCamera):
    def __init__(self, config: V4L2OpenCVCameraConfig):
        super().__init__(config)
        self._v4l2_controls = dict(config.v4l2_controls)
        self._v4l2_device = (
            f"/dev/video{config.index_or_path}"
            if isinstance(config.index_or_path, int)
            else str(config.index_or_path)
        )

    def connect(self, *args: Any, **kwargs: Any) -> None:
        super().connect(*args, **kwargs)
        _apply_v4l2_controls(self._v4l2_device, self._v4l2_controls)


@CameraConfig.register_subclass("hsv_opencv")
@dataclass
class HsvOpenCVCameraConfig(V4L2OpenCVCameraConfig):
    """V4L2OpenCVCameraConfig + HSV 후처리 파라미터.

    기본 v4l2_controls 를 top 카메라(USB 2.0 Camera) 용 반사광 완화 프리셋으로 오버라이드.
    Applied in order on V: gamma → CLAHE. Applied on S: saturation scale (S * s_scale, clipped to 255).
    각각 기본값이면 비활성: v_gamma=1.0, clahe_clip_limit<=0, s_scale=1.0.
    """

    # gamma > 1 어둡게, gamma < 1 밝게. 1.0 이면 비활성.
    v_gamma: float = 3.0
    # clip_limit <= 0 이면 CLAHE 비활성. 낮음(1~2): 자연스러움. 높음(3~5): 그림자/역광에 공격적.
    clahe_clip_limit: float = 4.0
    # tile_grid_size 큼: 세부 대비 ↑. 작음: 전체 대비 ↑.
    clahe_tile_grid_size: int = 8
    # 채도 배율. > 1 색 진하게, < 1 색 옅게.
    s_scale: float = 1.0

    # top 카메라용 v4l2: 반사광 완화를 위한 manual WB + 짧은 exposure.
    v4l2_controls: dict[str, int] = field(
        default_factory=lambda: {
            "white_balance_automatic": 0,
            "white_balance_temperature": 5000,
            "auto_exposure": 1,
            "exposure_time_absolute": 80,
            "saturation": 255,
        }
    )


class HsvOpenCVCamera(V4L2OpenCVCamera):
    def __init__(self, config: HsvOpenCVCameraConfig):
        super().__init__(config)
        self._v_gamma = config.v_gamma
        self._gamma_lut = None
        if self._v_gamma != 1.0:
            self._gamma_lut = np.array(
                [((i / 255.0) ** self._v_gamma) * 255.0 for i in range(256)]
            ).astype(np.uint8)

        self._clahe = None
        if config.clahe_clip_limit > 0:
            self._clahe = cv2.createCLAHE(
                clipLimit=config.clahe_clip_limit,
                tileGridSize=(config.clahe_tile_grid_size, config.clahe_tile_grid_size),
            )

        self._s_scale = config.s_scale

    def _postprocess_image(self, image: NDArray[Any]) -> NDArray[Any]:
        h, w, c = image.shape
        if h != self.capture_height or w != self.capture_width:
            raise RuntimeError(
                f"{self} frame width={w} or height={h} do not match configured "
                f"width={self.capture_width} or height={self.capture_height}."
            )
        if c != 3:
            raise RuntimeError(f"{self} frame channels={c} do not match expected 3 channels.")

        # BGR → HSV, gamma→CLAHE on V, scale on S, HSV → BGR
        hsv = cv2.cvtColor(image, cv2.COLOR_BGR2HSV)
        h_ch, s_ch, v_ch = cv2.split(hsv)
        if self._gamma_lut is not None:
            v_ch = cv2.LUT(v_ch, self._gamma_lut)
        if self._clahe is not None:
            v_ch = self._clahe.apply(v_ch)
        if self._s_scale != 1.0:
            s_ch = np.clip(s_ch.astype(np.float32) * self._s_scale, 0, 255).astype(np.uint8)
        equalized_bgr = cv2.cvtColor(cv2.merge([h_ch, s_ch, v_ch]), cv2.COLOR_HSV2BGR)

        out = equalized_bgr
        if self.color_mode == ColorMode.RGB:
            out = cv2.cvtColor(out, cv2.COLOR_BGR2RGB)
        if self.rotation in (
            cv2.ROTATE_90_CLOCKWISE,
            cv2.ROTATE_90_COUNTERCLOCKWISE,
            cv2.ROTATE_180,
        ):
            out = cv2.rotate(out, self.rotation)
        return out
