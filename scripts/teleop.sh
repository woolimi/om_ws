# wrist: Innomaker-U20CAM-720P (/dev/video2)
# top: USB 2.0 Camera (/dev/video0)

lerobot-teleoperate \
  --robot.type=omx_follower \
  --robot.port=/dev/omx_follower \
  --robot.id=omx_follower_arm \
  --robot.cameras="{ top: {type: opencv, index_or_path: 2, width: 640, height: 480, fps: 30}, wrist: {type: opencv, index_or_path: 0, width: 640, height: 480, fps: 30}}" \
  --teleop.type=omx_leader \
  --teleop.port=/dev/omx_leader \
  --teleop.id=omx_leader_arm \
  --display_data=true