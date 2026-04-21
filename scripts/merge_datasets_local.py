#!/usr/bin/env python
"""Merge multiple local LeRobot datasets (data/ 폴더들) into one.
Called by merge.sh with selected folder names and output repo_id.
"""
import argparse
import sys
from pathlib import Path

from lerobot.datasets.lerobot_dataset import LeRobotDataset
from lerobot.datasets.dataset_tools import merge_datasets


def main():
    parser = argparse.ArgumentParser(description="Merge local datasets under data/")
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path("data"),
        help="Parent directory containing dataset folders (default: data)",
    )
    parser.add_argument(
        "--folders",
        nargs="+",
        required=True,
        help="Dataset folder names to merge (e.g. task_a task_b)",
    )
    parser.add_argument(
        "--output-repo-id",
        type=str,
        default="woolim/merged",
        help="Output repo_id for merged dataset (default: woolim/merged)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Output directory. Default: <data-dir>/<output-repo_id with / replaced by _>",
    )
    args = parser.parse_args()

    data_dir = args.data_dir.resolve()
    if not data_dir.is_dir():
        print(f"Error: data dir not found: {data_dir}")
        sys.exit(1)

    output_repo_id = args.output_repo_id
    output_dir = args.output_dir
    if output_dir is None:
        output_dir = data_dir / output_repo_id.replace("/", "_")

    datasets_to_merge = []
    for folder in args.folders:
        root = data_dir / folder
        if not root.is_dir():
            print(f"Error: folder not found: {root}")
            sys.exit(1)
        repo_id = f"local/{folder}"
        ds = LeRobotDataset(repo_id=repo_id, root=root)
        datasets_to_merge.append(ds)
        print(f"  Loaded: {folder} ({ds.meta.total_episodes} episodes, {ds.meta.total_frames} frames)")

    if len(datasets_to_merge) < 2:
        print("Error: need at least 2 datasets to merge.")
        sys.exit(1)

    print(f"\nMerging into {output_repo_id} at {output_dir}")
    merged = merge_datasets(
        datasets_to_merge,
        output_repo_id=output_repo_id,
        output_dir=output_dir,
    )
    print(f"Done. Merged: {merged.meta.total_episodes} episodes, {merged.meta.total_frames} frames")
    print(f"Output: {output_dir}")


if __name__ == "__main__":
    main()
