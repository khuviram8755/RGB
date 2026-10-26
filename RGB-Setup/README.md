# GPU RGB and DeepCool LCD Setup

## Fresh Ubuntu installation

1. Make sure the NVIDIA driver is installed and `nvidia-smi` works.
2. Make sure the target machine has the expected MSI Mystic Light and DeepCool hardware.
3. Ensure the RGB GitLab repository is accessible from the target machine. For a private repository, configure GitLab authentication.
4. Run:

```bash
chmod +x setup_rgb_lcd.sh
sudo bash ./setup_rgb_lcd.sh
```

The installer creates two independent systemd services:
- `gpu-rgb-control.service`: NVIDIA GPU temperature -> MSI Mystic Light RGB.
- `deepcool-lcd.service`: DeepCool LD-Series LCD.

Thresholds: below 50 C is green; 50 C through 70 C is yellow; above 70 C is red.

## Service checks

```bash
sudo systemctl status gpu-rgb-control.service
sudo systemctl status deepcool-lcd.service
sudo journalctl -u gpu-rgb-control.service -f
sudo journalctl -u deepcool-lcd.service -f
```

## Repository configuration

The defaults in the installer are:
- Repository: `https://gitlab.com/infobay-ai-group3954639/rgb_setup.git`
- Branch: `feature/rgb-deepcool-setup`

Override them if needed:

```bash
sudo env RGB_REPO_URL="YOUR_REPOSITORY_URL" RGB_REPO_BRANCH="YOUR_BRANCH" bash setup_rgb_lcd.sh
```

The installer requires `rgb-placa.py` to exist somewhere in the cloned repository.


## Persistence and automatic recovery

The installer enables both systemd services at boot. The RGB controller continuously retries
GPU-temperature reads and RGB commands. Both services use `Restart=always`, so systemd
restarts their process if it exits, with no start-rate limit. This improves recovery from
process crashes but cannot guarantee recovery from hardware faults, missing USB devices,
driver failures, or incompatible firmware.

Check service state:
```bash
sudo systemctl status gpu-rgb-control.service deepcool-lcd.service
sudo journalctl -u gpu-rgb-control.service -u deepcool-lcd.service -b --no-pager
```

Confirm boot persistence:
```bash
systemctl is-enabled gpu-rgb-control.service deepcool-lcd.service
```
