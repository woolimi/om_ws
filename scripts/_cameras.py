"""config.json 에서 카메라 설정을 읽어 --robot.cameras 에 넘길 flow-YAML 문자열로 출력.

Shell 스크립트(record.sh/inference.sh/teleop.sh)가 이 스크립트를 호출해
CAMERAS_JSON 을 얻는다. 환경변수 대신 config.json 을 단일 출처로 사용하기 위함.

사용:
  CAMERAS_JSON=$(python3 scripts/_cameras.py)           # full flow-YAML
  FPS=$(python3 scripts/_cameras.py --key camera_fps)   # 단일 값 출력
"""

import argparse
import json
import sys
from pathlib import Path

CONFIG_PATH = Path(__file__).parent / "config.json"
REQUIRED = ("camera_top", "camera_wrist", "camera_width", "camera_height", "camera_fps")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--key", help="출력할 개별 키 (미지정 시 전체 CAMERAS_JSON 출력)")
    args = parser.parse_args()

    if not CONFIG_PATH.exists():
        print(f"Error: {CONFIG_PATH} not found", file=sys.stderr)
        return 1
    try:
        cfg = json.loads(CONFIG_PATH.read_text())
    except json.JSONDecodeError as e:
        print(f"Error: {CONFIG_PATH} is not valid JSON: {e}", file=sys.stderr)
        return 1

    if args.key:
        if args.key not in cfg:
            print(f"Error: '{args.key}' missing in {CONFIG_PATH}", file=sys.stderr)
            return 1
        print(cfg[args.key])
        return 0

    missing = [k for k in REQUIRED if k not in cfg]
    if missing:
        print(f"Error: missing keys in {CONFIG_PATH}: {missing}", file=sys.stderr)
        return 1

    w, h, fps = cfg["camera_width"], cfg["camera_height"], cfg["camera_fps"]
    cam_base = f"width: {w}, height: {h}, fps: {fps}"
    print(
        f"{{ top: {{type: hsv_opencv, index_or_path: {cfg['camera_top']}, {cam_base}}}, "
        f"wrist: {{type: v4l2_opencv, index_or_path: {cfg['camera_wrist']}, {cam_base}}} }}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
