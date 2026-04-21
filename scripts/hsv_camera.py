"""HSV V-channel equalized OpenCV camera.

BGR → HSV 로 변환 후 V (밝기) 채널에 CLAHE를 적용해 조명 편차를 줄인다.
H, S (색상·채도) 는 건드리지 않아서 색 정보는 보존.

사용: --robot.cameras="{ top: {type: hsv_opencv, index_or_path: 2, width: 640, height: 480, fps: 30} }"
"""

from dataclasses import dataclass
from typing import Any

import cv2
import numpy as np
from numpy.typing import NDArray

from lerobot.cameras.configs import CameraConfig, ColorMode
from lerobot.cameras.opencv import OpenCVCamera, OpenCVCameraConfig


@CameraConfig.register_subclass("hsv_opencv")
@dataclass
class HsvOpenCVCameraConfig(OpenCVCameraConfig):
    """OpenCVCameraConfig + HSV tunables.

    Applied in order on V: gamma → CLAHE.
    Applied on S: saturation scale (S * s_scale, clipped to 255).
    각각 기본값이면 비활성:
    - `v_gamma = 1.0` 스킵
    - `clahe_clip_limit <= 0` 스킵
    - `s_scale = 1.0` 스킵
    """

    # gamma > 1 어둡게, gamma < 1 밝게. 1.0 이면 비활성.
    v_gamma: float = 1.0
    clahe_clip_limit: float = 2.0
    clahe_tile_grid_size: int = 8
    # 채도 배율. > 1 색 진하게 (노랑/연두 구분 ↑), < 1 색 옅게.
    s_scale: float = 1.0


class HsvOpenCVCamera(OpenCVCamera):
    def __init__(self, config: HsvOpenCVCameraConfig):
        super().__init__(config)
        self._v_gamma = config.v_gamma
        self._gamma_lut = None
        if self._v_gamma != 1.0:
            # 미리 계산된 룩업 테이블 (0~255 → gamma 적용된 값)
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
        # Parent: dims check, BGR→RGB (if configured), rotation.
        # We want the equalization to run on raw BGR before color conversion/rotation,
        # so we apply it first, then delegate to parent for the rest.
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

        # Parent handles color_mode conversion + rotation, but it also does the dim check again.
        # Re-use the same parent pipeline by feeding equalized BGR in.
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
