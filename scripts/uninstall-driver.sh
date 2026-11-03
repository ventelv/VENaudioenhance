#!/bin/zsh
# Removes VEN Enhanced Mic from CoreAudio. Needs your admin password.
set -euo pipefail
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VENMic.driver
sudo killall coreaudiod
echo "Removed VEN Enhanced Mic."
