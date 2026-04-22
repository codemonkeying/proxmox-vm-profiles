#!/bin/bash
# Example per-VM post-start hook for start.sh.
# Copy to hook.sh and chmod +x to activate for this VM.
# start.sh calls this as:   hook.sh <VMID> <PROFILE>
# after `qm start` succeeds. Non-zero exit is logged but does not abort.

VMID=$1
PROFILE=$2

echo "[hook] VM ${VMID} started with profile ${PROFILE}"

# Example: detect a specific USB device and run a conditional fix.
# (Leave commented unless you actually want the fix.)
#
# if lsusb | grep -q "046d:c52b"; then
#     echo "[hook] Logitech Unifying Receiver detected — running post-start fix"
#     /root/fix-logi-flag.sh || echo "[hook] fix script failed, ignoring"
# fi
