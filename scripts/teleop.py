"""Wrapper around lerobot-teleoperate that registers our HSV preprocessing camera."""

import hsv_camera  # noqa: F401  — registers "hsv_opencv" camera type
from lerobot.scripts.lerobot_teleoperate import main

if __name__ == "__main__":
    main()
