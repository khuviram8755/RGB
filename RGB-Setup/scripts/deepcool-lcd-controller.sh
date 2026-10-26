#!/usr/bin/env bash
# DeepCool LCD-only controller. Installed at /opt/deepcool/deepcool-lcd-controller.sh
set -Eeuo pipefail
exec /opt/deepcool/deepcool-digital-linux --pid 10 --update 1000
