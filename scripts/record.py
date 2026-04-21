"""Wrapper around lerobot-record that registers our HSV preprocessing camera.

Equivalent to `lerobot-record` but with `type: hsv_opencv` available for camera configs.
"""

import hsv_camera  # noqa: F401  — registers "hsv_opencv" camera type
from lerobot.scripts.lerobot_record import main

if __name__ == "__main__":
    main()
