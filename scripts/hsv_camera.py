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

import json
import logging
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from numpy.typing import NDArray

from lerobot.cameras.configs import CameraConfig, ColorMode
from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig

CONFIG_PATH = Path(__file__).parent / "camera_config.json"


def load_camera_config() -> dict[str, Any]:
    """camera_config.json 읽기. 없거나 파싱 실패하면 빈 dict."""
    if not CONFIG_PATH.exists():
        return {}
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        logging.warning("Failed to read %s: %s", CONFIG_PATH, e)
        return {}


def save_camera_config(data: dict[str, Any]) -> None:
    """전체 dict 를 camera_config.json 에 저장."""
    with open(CONFIG_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


_CFG = load_camera_config()


def _top_config() -> dict[str, Any]:
    return _CFG.get("top", {})


def _wrist_config() -> dict[str, Any]:
    return _CFG.get("wrist", {})


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


_DEFAULT_WRIST_V4L2 = {
    "white_balance_automatic": 1,
    "auto_exposure": 3,
    "saturation": 64,
    "brightness": 0,
    "contrast": 32,
    "gamma": 100,
    "hue": 0,
}


@CameraConfig.register_subclass("v4l2_opencv")
@dataclass
class V4L2OpenCVCameraConfig(OpenCVCameraConfig):
    """OpenCVCameraConfig + connect() 이후 v4l2-ctl 자동 적용.

    기본값은 camera_config.json 의 wrist.v4l2_controls 에서 로드.
    """

    v4l2_controls: dict[str, int] = field(
        default_factory=lambda: dict(_wrist_config().get("v4l2_controls", _DEFAULT_WRIST_V4L2))
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


_DEFAULT_TOP_V4L2 = {
    "auto_exposure": 1,
    "exposure_time_absolute": 80,
    "saturation": 255,
}


@CameraConfig.register_subclass("hsv_opencv")
@dataclass
class HsvOpenCVCameraConfig(V4L2OpenCVCameraConfig):
    """V4L2OpenCVCameraConfig + HSV 후처리 파라미터.

    모든 기본값은 camera_config.json 의 top 섹션에서 로드.
    Applied in order on V: gamma → CLAHE. Applied on S: saturation scale (S * s_scale).
    각각 기본값이면 비활성: v_gamma=1.0, clahe_clip_limit<=0, s_scale=1.0.
    """

    v_gamma: float = _top_config().get("v_gamma", 3.0)
    clahe_clip_limit: float = _top_config().get("clahe_clip_limit", 4.0)
    clahe_tile_grid_size: int = _top_config().get("clahe_tile_grid_size", 8)
    s_scale: float = _top_config().get("s_scale", 1.0)

    v4l2_controls: dict[str, int] = field(
        default_factory=lambda: dict(_top_config().get("v4l2_controls", _DEFAULT_TOP_V4L2))
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
