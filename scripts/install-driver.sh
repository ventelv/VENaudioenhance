#!/bin/zsh
# Installs VEN Enhanced Mic into CoreAudio. Needs your admin password.
# Restarting coreaudiod interrupts all audio on the Mac for a second or two.
set -euo pipefail
ROOT="${0:A:h:h}"
"$ROOT/scripts/build-driver.sh"
sudo rm -rf /Library/Audio/Plug-Ins/HAL/VENMic.driver
sudo cp -R "$ROOT/build/VENMic.driver" /Library/Audio/Plug-Ins/HAL/
sudo chown -R root:wheel /Library/Audio/Plug-Ins/HAL/VENMic.driver
sudo killall coreaudiod
echo "Installed. 'VEN Enhanced Mic' should now appear as an input device."
