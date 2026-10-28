#!/usr/bin/env bash
# RGB-only controller. Installed at /opt/gpu-rgb/rgb-temperature-controller.sh
set -u
#RGB_CONTROLLER=/opt/gpu-rgb/rgb-placa.py"
INTERVAL="${INTERVAL:-5}"
while true; do
  TEMP="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n 1 || true)"
  if [[ ! "$TEMP" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not read a valid NVIDIA GPU temperature."
    sleep "$INTERVAL"; continue
  fi
  if (( TEMP < 50 )); then R=0; G=255; B=0; STATUS="GREEN"
  elif (( TEMP <= 70 )); then R=255; G=255; B=0; STATUS="YELLOW"
  else R=255; G=0; B=0; STATUS="RED"
  fi
  echo "GPU ${TEMP}C -> ${STATUS}"
  python3 "$RGB_CONTROLLER" "$R" "$G" "$B" temporal || echo "ERROR: RGB command failed."
  sleep "$INTERVAL"
done
