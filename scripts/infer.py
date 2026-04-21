# Copyright 2024 The HuggingFace Inc. team. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
"""
Infinite policy inference without recording.

Reuses `record_loop` from `lerobot_record` but:
- Loops forever until Ctrl+C (num_episodes ignored).
- Never calls `save_episode()` (dataset buffer is cleared each iteration).
- Dataset root defaults to /dev/shm (RAM) so zero disk I/O for frames.

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
from dataclasses import asdict, dataclass
from pathlib import Path
from pprint import pformat

from lerobot.configs import PreTrainedConfig, parser
from lerobot.datasets import (
    LeRobotDataset,
    VideoEncodingManager,
    aggregate_pipeline_dataset_features,
    create_initial_features,
)
from lerobot.policies import (
    ActionInterpolator,
    make_policy,
    make_pre_post_processors,
)
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
from lerobot.scripts.lerobot_record import record_loop
from lerobot.utils.feature_utils import combine_feature_dicts
from lerobot.utils.import_utils import register_third_party_plugins
from lerobot.utils.utils import init_logging, log_say
from lerobot.utils.visualization_utils import init_rerun
from lerobot.common.control_utils import init_keyboard_listener, is_headless


@dataclass
class InferConfig:
    robot: RobotConfig
    policy: PreTrainedConfig | None = None
    # Task description passed to the policy each frame.
    single_task: str = "Policy inference"
    # Control loop FPS (must match policy training FPS).
    fps: int = 30
    # Length of one inference pass in seconds. Loop starts a new pass immediately after.
    episode_time_s: float = 60.0
    # Scratch dataset root — defaults to RAM so no disk writes.
    dataset_root: str = "/dev/shm/lerobot_infer"
    # Display cameras/actions via Rerun.
    display_data: bool = False
    display_ip: str | None = None
    display_port: int | None = None
    display_compressed_images: bool = False
    # Speak status messages.
    play_sounds: bool = False
    # Smoother policy control (1 = off).
    interpolation_multiplier: int = 1

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

    # Scratch dataset lives in RAM and is recreated on each run. It's only needed for
    # feature schema + buffer during a pass — we never call save_episode().
    dataset_root = Path(cfg.dataset_root)
    if dataset_root.exists():
        import shutil

        shutil.rmtree(dataset_root)

    dataset = None
    listener = None

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

        interpolator = None
        if cfg.interpolation_multiplier > 1:
            interpolator = ActionInterpolator(multiplier=cfg.interpolation_multiplier)
            logging.info(f"Action interpolation: {cfg.interpolation_multiplier}x")

        robot.connect()
        listener, events = init_keyboard_listener()

        log_say("Inference starting (Ctrl+C to stop)", cfg.play_sounds)

        with VideoEncodingManager(dataset):
            iteration = 0
            while not events["stop_recording"]:
                log_say(f"Inference pass {iteration}", cfg.play_sounds)
                record_loop(
                    robot=robot,
                    events=events,
                    fps=cfg.fps,
                    teleop_action_processor=teleop_action_processor,
                    robot_action_processor=robot_action_processor,
                    robot_observation_processor=robot_observation_processor,
                    teleop=None,
                    policy=policy,
                    preprocessor=preprocessor,
                    postprocessor=postprocessor,
                    dataset=dataset,
                    control_time_s=cfg.episode_time_s,
                    single_task=cfg.single_task,
                    display_data=cfg.display_data,
                    interpolator=interpolator,
                    display_compressed_images=display_compressed_images,
                )
                # Drop the buffered frames — we're not saving episodes.
                dataset.clear_episode_buffer()
                iteration += 1
    finally:
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
