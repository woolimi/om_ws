# Copyright 2024 The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
"""
Infinite policy inference without recording.

Lightweight control loop that avoids `record_loop`/`dataset.add_frame` overhead:
- Loops forever until Ctrl+C (num_episodes ignored).
- No `save_episode()`, no buffered frames, no video encoding.
- Dataset root defaults to /dev/shm (RAM, Linux) with a tempdir fallback on platforms
  without tmpfs (e.g. macOS). The scratch dataset is created only to obtain the feature
  schema/stats needed by `make_policy` and `make_pre_post_processors`.

Run:
    python -m lerobot.scripts.lerobot_infer \
        --robot.type=omx_follower --robot.port=/dev/omx_follower \
        --robot.id=omx_follower_arm \
        --robot.cameras="{ top: {type: opencv, index_or_path: 2, width: 640, height: 480, fps: 30} }" \
        --policy.path=outputs/train/act_v1/checkpoints/last/pretrained_model \
        --single_task="Pick up Doll" \
        --display_data=true
"""

import logging
import signal
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from pprint import pformat

import cv2

from lerobot.cameras import CameraConfig  # noqa: F401  — ensures camera ChoiceRegistry is loaded
from lerobot.cameras.opencv import OpenCVCameraConfig  # noqa: F401  — registers "opencv" choice
import hsv_camera  # noqa: F401  — registers "hsv_opencv" camera type
from lerobot.common.control_utils import init_keyboard_listener, is_headless, predict_action
from lerobot.configs import PreTrainedConfig, parser
from lerobot.datasets import (
    LeRobotDataset,
    aggregate_pipeline_dataset_features,
    create_initial_features,
)
from lerobot.policies import (
    make_policy,
    make_pre_post_processors,
)
from lerobot.policies.utils import make_robot_action
from lerobot.processor import (
    make_default_processors,
    rename_stats,
)
from lerobot.robots import (  # noqa: F401
    RobotConfig,
    bi_openarm_follower,
    bi_so_follower,
    earthrover_mini_plus,
    hope_jr,
    koch_follower,
    make_robot_from_config,
    omx_follower,
    openarm_follower,
    reachy2,
    so_follower,
    unitree_g1 as unitree_g1_robot,
)
from lerobot.utils.constants import OBS_STR
from lerobot.utils.device_utils import get_safe_torch_device
from lerobot.utils.feature_utils import build_dataset_frame, combine_feature_dicts
from lerobot.utils.import_utils import register_third_party_plugins
from lerobot.utils.robot_utils import precise_sleep
from lerobot.utils.utils import init_logging, log_say
from lerobot.utils.visualization_utils import init_rerun, log_rerun_data


@dataclass
class InferConfig:
    robot: RobotConfig
    policy: PreTrainedConfig | None = None
    # Task description passed to the policy each frame.
    single_task: str = "Policy inference"
    # Control loop FPS (must match policy training FPS).
    fps: int = 30
    # Length of one inference pass in seconds. Loop starts a new pass immediately after.
    episode_time_s: float = 10.0
    # Scratch dataset root — Linux: /dev/shm (RAM); other platforms: system tempdir.
    dataset_root: str = field(
        default_factory=lambda: str(
            Path("/dev/shm" if Path("/dev/shm").is_dir() else tempfile.gettempdir())
            / "lerobot_infer"
        )
    )
    # Display cameras/actions via Rerun.
    display_data: bool = False
    display_ip: str | None = None
    display_port: int | None = None
    display_compressed_images: bool = False
    # Speak status messages via system TTS (macOS `say`, Linux `spd-say`).
    play_sounds: bool = True
    # Save the top camera stream to an .mp4 during inference. None disables.
    record_top_video_path: str | None = None

    def __post_init__(self):
        # Mirror RecordConfig: re-parse policy path so --policy.path loads the checkpoint config.
        policy_path = parser.get_path_arg("policy")
        if policy_path:
            cli_overrides = parser.get_cli_overrides("policy")
            self.policy = PreTrainedConfig.from_pretrained(policy_path, cli_overrides=cli_overrides)
            self.policy.pretrained_path = policy_path

        if self.policy is None:
            raise ValueError("Policy is required for inference. Pass --policy.path=<checkpoint_dir>.")

    @classmethod
    def __get_path_fields__(cls) -> list[str]:
        return ["policy"]


@parser.wrap()
def infer(cfg: InferConfig) -> None:
    init_logging()
    logging.info(pformat(asdict(cfg)))
    if cfg.display_data:
        init_rerun(session_name="inference", ip=cfg.display_ip, port=cfg.display_port)
    display_compressed_images = (
        True
        if (cfg.display_data and cfg.display_ip is not None and cfg.display_port is not None)
        else cfg.display_compressed_images
    )

    robot = make_robot_from_config(cfg.robot)

    teleop_action_processor, robot_action_processor, robot_observation_processor = make_default_processors()

    dataset_features = combine_feature_dicts(
        aggregate_pipeline_dataset_features(
            pipeline=teleop_action_processor,
            initial_features=create_initial_features(action=robot.action_features),
            use_videos=True,
        ),
        aggregate_pipeline_dataset_features(
            pipeline=robot_observation_processor,
            initial_features=create_initial_features(observation=robot.observation_features),
            use_videos=True,
        ),
    )

    # Scratch dataset lives in RAM (Linux) or tempdir. Created only to derive feature schema + stats.
    # It is never written to during the loop — no add_frame, no save_episode, no video encoding.
    dataset_root = Path(cfg.dataset_root)
    if dataset_root.exists():
        import shutil

        shutil.rmtree(dataset_root)

    dataset = None
    listener = None
    top_video_writer = None
    top_video_path = Path(cfg.record_top_video_path) if cfg.record_top_video_path else None
    if top_video_path is not None:
        top_video_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        dataset = LeRobotDataset.create(
            repo_id="local/infer_scratch",
            fps=cfg.fps,
            root=dataset_root,
            robot_type=robot.name,
            features=dataset_features,
            use_videos=True,
            image_writer_processes=0,
            image_writer_threads=0,
            batch_encoding_size=1,
        )

        policy = make_policy(cfg.policy, ds_meta=dataset.meta)
        preprocessor, postprocessor = make_pre_post_processors(
            policy_cfg=cfg.policy,
            pretrained_path=cfg.policy.pretrained_path,
            dataset_stats=rename_stats(dataset.meta.stats, {}),
            preprocessor_overrides={
                "device_processor": {"device": cfg.policy.device},
                "rename_observations_processor": {"rename_map": {}},
            },
        )

        device = get_safe_torch_device(cfg.policy.device)
        control_interval = 1.0 / cfg.fps
        features = dataset.features  # local ref — avoids attr lookup inside the hot loop

        robot.connect()
        listener, events = init_keyboard_listener()

        log_say("Let's start inference bro!! (Ctrl+C to stop)", cfg.play_sounds)

        iteration = 0
        while not events["stop_recording"]:
            log_say(f"Inference pass {iteration}", cfg.play_sounds)
            policy.reset()
            preprocessor.reset()
            postprocessor.reset()

            episode_start_t = time.perf_counter()
            while (time.perf_counter() - episode_start_t) < cfg.episode_time_s:
                if events["exit_early"]:
                    events["exit_early"] = False
                    break
                if events["stop_recording"]:
                    break

                loop_start_t = time.perf_counter()

                obs = robot.get_observation()
                obs_processed = robot_observation_processor(obs)
                observation_frame = build_dataset_frame(features, obs_processed, prefix=OBS_STR)

                if top_video_path is not None:
                    top_frame = obs_processed.get("top")
                    if top_frame is not None:
                        if top_video_writer is None:
                            h, w = top_frame.shape[:2]
                            fourcc = cv2.VideoWriter_fourcc(*"mp4v")
                            top_video_writer = cv2.VideoWriter(
                                str(top_video_path), fourcc, cfg.fps, (w, h)
                            )
                            logging.info(
                                f"Recording top camera to {top_video_path} ({w}x{h} @ {cfg.fps}fps)"
                            )
                        top_video_writer.write(cv2.cvtColor(top_frame, cv2.COLOR_RGB2BGR))

                action_values = predict_action(
                    observation=observation_frame,
                    policy=policy,
                    device=device,
                    preprocessor=preprocessor,
                    postprocessor=postprocessor,
                    use_amp=cfg.policy.use_amp,
                    task=cfg.single_task,
                    robot_type=robot.robot_type,
                )

                act_processed_policy = make_robot_action(action_values, features)
                robot_action_to_send = robot_action_processor((act_processed_policy, obs))
                robot.send_action(robot_action_to_send)

                if cfg.display_data:
                    log_rerun_data(
                        observation=obs_processed,
                        action=robot_action_to_send,
                        compress_images=display_compressed_images,
                    )

                dt_s = time.perf_counter() - loop_start_t
                sleep_s = control_interval - dt_s
                if sleep_s < 0:
                    logging.warning(
                        f"Inference loop running slower ({1.0 / dt_s:.1f} Hz) than target ({cfg.fps} Hz)."
                    )
                precise_sleep(max(sleep_s, 0.0))

            iteration += 1
    finally:
        # mp4 moov atom 이 써지기 전에 두 번째 Ctrl+C 가 들어와 release 가 스킵되면
        # 영상이 재생 불가 상태로 남음. release 동안 SIGINT 를 무시해서 반드시 완료시킴.
        if top_video_writer is not None:
            prev_sigint = signal.signal(signal.SIGINT, signal.SIG_IGN)
            try:
                top_video_writer.release()
                logging.info(f"Saved top camera video to {top_video_path}")
            except Exception as e:
                logging.error(f"Failed to release video writer: {e}")
            finally:
                signal.signal(signal.SIGINT, prev_sigint)

        log_say("Stopping inference", cfg.play_sounds, blocking=True)

        if robot.is_connected:
            robot.disconnect()
        if not is_headless() and listener:
            listener.stop()
        log_say("Exiting", cfg.play_sounds)


def main():
    register_third_party_plugins()
    infer()


if __name__ == "__main__":
    main()
