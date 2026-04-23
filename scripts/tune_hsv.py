"""카메라 전처리 파라미터 실시간 튜닝 도구 (tkinter UI).

scripts/camera_config.json 의 값을 로드해 시작 상태를 만들고, 슬라이더로 조정 후
[Save] 버튼으로 같은 파일에 저장. hsv_camera.py 가 자동으로 읽으므로 추론/녹화
스크립트에 즉시 반영됨.

사용:
  python scripts/tune_hsv.py                       # top 카메라 튜닝 (기본)
  CAMERA_SECTION=wrist python scripts/tune_hsv.py  # wrist 카메라 튜닝
  CAMERA_INDEX=1 python scripts/tune_hsv.py        # 인덱스 수동 지정
"""

import json
import os
import subprocess
import sys
import tkinter as tk
from tkinter import ttk

import cv2
import numpy as np
from PIL import Image, ImageTk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hsv_camera import (  # noqa: E402
    HsvOpenCVCameraConfig,
    V4L2OpenCVCameraConfig,
    load_camera_config,
    save_camera_config,
)

# v4l2 컨트롤 → (min, max, step, description)
V4L2_CONTROL_META = {
    "white_balance_automatic": (0, 1, 1, "1=auto WB on, 0=manual"),
    "white_balance_temperature": (2000, 7500, 100, "color temp in Kelvin; lower=warmer"),
    "auto_exposure": (0, 3, 1, "1=manual exposure, 3=auto"),
    "exposure_time_absolute": (1, 500, 1, "exposure time; lower=darker & less glare"),
    "saturation": (0, 255, 1, "hardware saturation"),
    "brightness": (0, 255, 1, "brightness"),
    "contrast": (0, 255, 1, "contrast"),
    "gamma": (0, 255, 1, "gamma"),
    "sharpness": (0, 15, 1, "sharpness"),
    "hue": (0, 360, 1, "hue rotation"),
    "backlight_compensation": (0, 2, 1, "backlight compensation"),
    "power_line_frequency": (0, 2, 1, "0=off, 1=50Hz, 2=60Hz"),
}


def apply_hsv(image_bgr, v_gamma, clahe_clip_limit, clahe_tile_grid_size, s_scale):
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
    if sys.platform != "linux" or not controls:
        return
    cmd = ["v4l2-ctl", "-d", device]
    for key, value in controls.items():
        cmd.append(f"--set-ctrl={key}={int(value)}")
    try:
        subprocess.run(cmd, check=False, capture_output=True, text=True)
    except FileNotFoundError:
        pass


class LabeledSlider(ttk.Frame):
    """라벨 + 슬라이더 + 현재값 + 설명 한 줄."""

    def __init__(self, parent, label, min_v, max_v, initial, step=1.0, desc="",
                 is_float=False, on_change=None):
        super().__init__(parent)
        self.is_float = is_float
        self.on_change = on_change
        self._updating = False

        # 1행: 라벨(왼), 값(오른)
        top = ttk.Frame(self)
        top.pack(fill="x")
        ttk.Label(top, text=label, font=("TkDefaultFont", 10, "bold")).pack(side="left")
        self.value_lbl = ttk.Label(top, text="", font=("TkFixedFont", 10), foreground="#0066cc")
        self.value_lbl.pack(side="right")

        # 2행: 슬라이더
        # float 인 경우 내부적으로 *100 스케일로 저장
        self._scale_factor = 100 if is_float else 1
        self.var = tk.IntVar(value=int(round(initial * self._scale_factor)))
        self.scale = ttk.Scale(
            self, from_=int(min_v * self._scale_factor), to=int(max_v * self._scale_factor),
            variable=self.var, orient="horizontal", command=self._on_slider,
        )
        self.scale.pack(fill="x", pady=(2, 0))

        # 3행: 설명 (있으면)
        if desc:
            ttk.Label(self, text=desc, foreground="#666", font=("TkDefaultFont", 8)).pack(anchor="w")

        self._refresh_value_label()

    def _on_slider(self, _):
        if self._updating:
            return
        self._refresh_value_label()
        if self.on_change:
            self.on_change(self.get())

    def _refresh_value_label(self):
        v = self.get()
        if self.is_float:
            self.value_lbl.configure(text=f"{v:.2f}")
        else:
            self.value_lbl.configure(text=f"{int(v)}")

    def get(self):
        return self.var.get() / self._scale_factor if self.is_float else self.var.get()

    def set(self, value):
        self._updating = True
        self.var.set(int(round(value * self._scale_factor)) if self.is_float else int(value))
        self._refresh_value_label()
        self._updating = False


class TunerApp:
    def __init__(self, section, index, width, height, fps):
        self.section = section
        self.show_hsv = section == "top"
        self.device = f"/dev/video{index}"
        self.width = width
        self.height = height

        # 기본값
        if section == "top":
            self.defaults = HsvOpenCVCameraConfig(index_or_path=0)
        else:
            self.defaults = V4L2OpenCVCameraConfig(index_or_path=0)

        # 카메라
        self.cap = cv2.VideoCapture(index)
        if not self.cap.isOpened():
            raise RuntimeError(f"cannot open camera index {index}")
        self.cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        self.cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        self.cap.set(cv2.CAP_PROP_FPS, fps)

        self.current_v4l2 = dict(self.defaults.v4l2_controls)
        apply_v4l2(self.device, self.current_v4l2)

        # UI
        self.root = tk.Tk()
        self.root.title(f"Camera Tuner — {section}  (/dev/video{index})")
        self._build_ui()

        # 프리뷰 표시용 변수 (tkinter garbage collector 방지)
        self._imgtk_raw = None
        self._imgtk_proc = None

        self._update_preview()

    def _build_ui(self):
        # 루트 레이아웃: 좌 컨트롤 패널 / 우 프리뷰
        main = ttk.PanedWindow(self.root, orient="horizontal")
        main.pack(fill="both", expand=True)

        # === 좌측 컨트롤 ===
        controls = ttk.Frame(main, padding=10)
        main.add(controls, weight=0)

        # scrollable canvas 로 많은 슬라이더 담기
        canvas = tk.Canvas(controls, width=360, highlightthickness=0)
        scrollbar = ttk.Scrollbar(controls, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        inner = ttk.Frame(canvas)
        canvas.create_window((0, 0), window=inner, anchor="nw")
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        # 마우스 휠 스크롤
        canvas.bind_all("<Button-4>", lambda e: canvas.yview_scroll(-1, "units"))
        canvas.bind_all("<Button-5>", lambda e: canvas.yview_scroll(1, "units"))
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(-1 * (e.delta // 120), "units"))

        self.hsv_sliders = {}
        self.v4l2_sliders = {}

        # HSV section (top only)
        if self.show_hsv:
            ttk.Label(inner, text="HSV post-processing", font=("TkDefaultFont", 12, "bold"),
                      foreground="#003366").pack(anchor="w", pady=(0, 5))

            self.hsv_sliders["v_gamma"] = LabeledSlider(
                inner, "v_gamma", 0.1, 5.0, self.defaults.v_gamma, is_float=True,
                desc=">1 darker / <1 brighter / 1.0 = disabled"
            )
            self.hsv_sliders["v_gamma"].pack(fill="x", pady=4)

            self.hsv_sliders["clahe_clip_limit"] = LabeledSlider(
                inner, "clahe_clip_limit", 0.0, 10.0, self.defaults.clahe_clip_limit,
                is_float=True, desc="0 = CLAHE off / 1~2 natural / 3~5 aggressive"
            )
            self.hsv_sliders["clahe_clip_limit"].pack(fill="x", pady=4)

            self.hsv_sliders["clahe_tile_grid_size"] = LabeledSlider(
                inner, "clahe_tile_grid_size", 2, 32, self.defaults.clahe_tile_grid_size,
                is_float=False, desc="larger = local detail / smaller = global contrast"
            )
            self.hsv_sliders["clahe_tile_grid_size"].pack(fill="x", pady=4)

            self.hsv_sliders["s_scale"] = LabeledSlider(
                inner, "s_scale", 0.1, 5.0, self.defaults.s_scale, is_float=True,
                desc=">1 more saturated / 1.0 = disabled"
            )
            self.hsv_sliders["s_scale"].pack(fill="x", pady=4)

            ttk.Separator(inner, orient="horizontal").pack(fill="x", pady=10)

        # v4l2 section
        ttk.Label(inner, text="v4l2 hardware controls", font=("TkDefaultFont", 12, "bold"),
                  foreground="#003366").pack(anchor="w", pady=(0, 5))

        for key, initial in self.current_v4l2.items():
            meta = V4L2_CONTROL_META.get(key, (0, 255, 1, ""))
            lo, hi, _step, desc = meta
            slider = LabeledSlider(
                inner, key, lo, hi, initial, is_float=False, desc=desc,
                on_change=self._on_v4l2_change,
            )
            slider.pack(fill="x", pady=4)
            self.v4l2_sliders[key] = slider

        # 버튼
        ttk.Separator(inner, orient="horizontal").pack(fill="x", pady=10)
        btns = ttk.Frame(inner)
        btns.pack(fill="x", pady=(0, 5))
        ttk.Button(btns, text="💾 Save", command=self._save, width=10).pack(side="left", padx=2)
        ttk.Button(btns, text="↺ Reset", command=self._reset, width=10).pack(side="left", padx=2)
        ttk.Button(btns, text="📋 Print", command=self._print, width=10).pack(side="left", padx=2)
        ttk.Button(btns, text="✖ Quit", command=self._quit, width=8).pack(side="left", padx=2)

        self.status_lbl = ttk.Label(inner, text="ready.", foreground="#006600")
        self.status_lbl.pack(anchor="w", pady=(5, 0))

        # === 우측 프리뷰 ===
        preview = ttk.Frame(main, padding=5)
        main.add(preview, weight=1)

        ttk.Label(preview, text=f"[{self.section}]   raw  →  processed",
                  font=("TkDefaultFont", 10, "bold")).pack(anchor="w")

        self.canvas_preview = tk.Label(preview, bg="#222")
        self.canvas_preview.pack(fill="both", expand=True, pady=5)

        # 창 닫기 핸들러
        self.root.protocol("WM_DELETE_WINDOW", self._quit)

    def _on_v4l2_change(self, _value):
        # 모든 v4l2 슬라이더 값을 읽어 current_v4l2 갱신 후 재적용
        for key, slider in self.v4l2_sliders.items():
            self.current_v4l2[key] = slider.get()
        apply_v4l2(self.device, self.current_v4l2)

    def _update_preview(self):
        ok, frame = self.cap.read()
        if ok:
            if self.show_hsv:
                v_gamma = self.hsv_sliders["v_gamma"].get()
                clahe_clip = self.hsv_sliders["clahe_clip_limit"].get()
                clahe_tile = self.hsv_sliders["clahe_tile_grid_size"].get()
                s_scale = self.hsv_sliders["s_scale"].get()
                processed = apply_hsv(frame, v_gamma, clahe_clip, clahe_tile, s_scale)
            else:
                processed = frame.copy()

            combined = np.hstack([frame, processed])
            combined_rgb = cv2.cvtColor(combined, cv2.COLOR_BGR2RGB)

            # 창 크기에 맞게 리사이즈 (첫 프레임은 widget 이 아직 배치되기 전이라
            # winfo_width() 가 1 을 반환할 수 있음 → 충분히 클 때만 리사이즈)
            max_w = self.canvas_preview.winfo_width()
            if max_w > 50:
                scale = min(max_w / combined_rgb.shape[1], 1.5)
                new_w = max(int(combined_rgb.shape[1] * scale), 1)
                new_h = max(int(combined_rgb.shape[0] * scale), 1)
                if (new_w, new_h) != (combined_rgb.shape[1], combined_rgb.shape[0]):
                    combined_rgb = cv2.resize(combined_rgb, (new_w, new_h))

            img = Image.fromarray(combined_rgb)
            self._imgtk_raw = ImageTk.PhotoImage(image=img)
            self.canvas_preview.configure(image=self._imgtk_raw)

        self.root.after(33, self._update_preview)

    def _current_section_dict(self):
        data = {"v4l2_controls": {k: int(s.get()) for k, s in self.v4l2_sliders.items()}}
        if self.show_hsv:
            data = {
                "v_gamma": float(self.hsv_sliders["v_gamma"].get()),
                "clahe_clip_limit": float(self.hsv_sliders["clahe_clip_limit"].get()),
                "clahe_tile_grid_size": int(self.hsv_sliders["clahe_tile_grid_size"].get()),
                "s_scale": float(self.hsv_sliders["s_scale"].get()),
                "v4l2_controls": {k: int(s.get()) for k, s in self.v4l2_sliders.items()},
            }
        return data

    def _reset(self):
        """Reload current section from camera_config.json into all sliders and re-apply v4l2."""
        full = load_camera_config() or {}
        section_data = full.get(self.section, {})

        if self.show_hsv:
            for key, slider in self.hsv_sliders.items():
                if key in section_data:
                    slider.set(section_data[key])

        v4l2_from_file = section_data.get("v4l2_controls", {})
        for key, slider in self.v4l2_sliders.items():
            if key in v4l2_from_file:
                slider.set(v4l2_from_file[key])
            self.current_v4l2[key] = slider.get()

        apply_v4l2(self.device, self.current_v4l2)
        self.status_lbl.configure(text=f"↺ reloaded from JSON ({self.section})", foreground="#cc6600")

    def _save(self):
        full = load_camera_config() or {}
        full[self.section] = self._current_section_dict()
        save_camera_config(full)
        self.status_lbl.configure(text=f"✓ saved ({self.section} section)", foreground="#006600")
        print(f"✓ saved to camera_config.json ({self.section} section)")

    def _print(self):
        data = self._current_section_dict()
        print("─" * 60)
        print(f"current [{self.section}] config:")
        print(json.dumps(data, indent=2, ensure_ascii=False))
        print("─" * 60)
        self.status_lbl.configure(text="printed to console", foreground="#333")

    def _quit(self):
        try:
            self.cap.release()
        except Exception:
            pass
        self.root.destroy()

    def run(self):
        self.root.mainloop()


def main():
    section = os.environ.get("CAMERA_SECTION", "top").lower()
    if section not in ("top", "wrist"):
        print(f"ERROR: CAMERA_SECTION must be 'top' or 'wrist' (got '{section}')", file=sys.stderr)
        sys.exit(1)

    if section == "top":
        default_index = int(os.environ.get("CAMERA_TOP_INDEX", 2))
    else:
        default_index = int(os.environ.get("CAMERA_WRIST_INDEX", 0))

    index = int(os.environ.get("CAMERA_INDEX", default_index))
    width = int(os.environ.get("CAMERA_WIDTH", 640))
    height = int(os.environ.get("CAMERA_HEIGHT", 480))
    fps = int(os.environ.get("CAMERA_FPS", 30))

    app = TunerApp(section, index, width, height, fps)
    app.run()


if __name__ == "__main__":
    main()
