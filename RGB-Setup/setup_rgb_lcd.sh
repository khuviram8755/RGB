#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Permanent MSI RGB + DeepCool LD-Series LCD Setup
# Supported OS: Ubuntu
# Run: sudo bash setup_rgb_lcd.sh
# ============================================================

# Automatically request sudo if not already running as root.
# exec replaces the current process; it does not open a root shell.
if [[ "$EUID" -ne 0 ]]; then
    echo "Administrator privileges required. Requesting sudo..."
    exec sudo -E bash "$0" "$@"
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
    echo "ERROR: This script requires Ubuntu."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

RGB_REPO="https://github.com/khuviram8755/RGB.git"
LCD_REPO="https://github.com/Nortank12/deepcool-digital-linux.git"

WORK="/var/tmp/rgb-lcd-setup"
RGB="/opt/gpu-rgb"
LCD="/opt/deepcool"

echo
echo "============================================================"
echo " MSI RGB + DeepCool LCD Permanent Setup"
echo "============================================================"
echo

# ------------------------------------------------------------
# 1. Install system dependencies
# ------------------------------------------------------------

echo "[1/9] Installing dependencies..."

apt-get update

apt-get install -y \
    git curl ca-certificates build-essential pkg-config \
    libudev-dev libusb-1.0-0-dev libhidapi-dev \
    libhidapi-hidraw0 libhidapi-libusb0 \
    python3 python3-venv python3-pip python3-hidapi \
    usbutils pciutils

# ------------------------------------------------------------
# 2. Verify NVIDIA driver
# ------------------------------------------------------------

echo "[2/9] Checking NVIDIA GPU..."

if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERROR: nvidia-smi is missing."
    echo "Install the NVIDIA driver, reboot, and run this script again."
    exit 1
fi

if ! nvidia-smi --query-gpu=name,temperature.gpu \
    --format=csv,noheader; then
    echo "ERROR: NVIDIA GPU temperature query failed."
    echo "Fix the NVIDIA driver before continuing."
    exit 1
fi

# ------------------------------------------------------------
# 3. Prepare installation directories
# ------------------------------------------------------------

echo "[3/9] Preparing directories..."

mkdir -p "$WORK" "$RGB" "$LCD"

# ------------------------------------------------------------
# 4. Install MSI RGB controller
# ------------------------------------------------------------

echo "[4/9] Downloading MSI RGB controller..."

rm -rf "$WORK/msi-rgb"

git clone --depth 1 "$RGB_REPO" "$WORK/msi-rgb"

RGB_SOURCE="$(
    find "$WORK/msi-rgb" -type f -name 'rgb-placa.py' -print -quit
)"

if [[ -z "$RGB_SOURCE" ]]; then
    echo "ERROR: rgb-placa.py was not found."
    exit 1
fi

install -m 0755 "$RGB_SOURCE" "$RGB/rgb-placa.py"

python3 -m venv --system-site-packages "$RGB/venv"

# ------------------------------------------------------------
# 5. Install Rust and build DeepCool LCD controller
# ------------------------------------------------------------

echo "[5/9] Installing Rust toolchain..."

export RUSTUP_HOME="/root/.rustup"
export CARGO_HOME="/root/.cargo"
export PATH="/root/.cargo/bin:$PATH"

if [[ ! -x /root/.cargo/bin/rustup ]]; then
    curl --proto '=https' --tlsv1.2 -fsSL \
        https://sh.rustup.rs \
        -o "$WORK/rustup-init.sh"

    sh "$WORK/rustup-init.sh" \
        -y --profile minimal --default-toolchain stable
fi

rustup default stable

echo "Downloading DeepCool LCD software..."

rm -rf "$WORK/deepcool"

git clone --depth 1 "$LCD_REPO" "$WORK/deepcool"

if [[ ! -f "$WORK/deepcool/Cargo.toml" ]]; then
    echo "ERROR: DeepCool Cargo.toml was not found."
    exit 1
fi

echo "Building DeepCool LCD controller..."

(
    cd "$WORK/deepcool"
    cargo build --release
)

LCD_BINARY="$WORK/deepcool/target/release/deepcool-digital-linux"

if [[ ! -x "$LCD_BINARY" ]]; then
    echo "ERROR: DeepCool binary was not built."
    exit 1
fi

install -m 0755 "$LCD_BINARY" "$LCD/deepcool-digital-linux"

# ------------------------------------------------------------
# 6. Configure USB device permissions
# ------------------------------------------------------------

echo "[6/9] Configuring USB permissions..."

getent group plugdev >/dev/null || groupadd --system plugdev

cat > /etc/udev/rules.d/70-rgb-deepcool.rules <<'UDEV'
SUBSYSTEM=="usb", ATTR{idVendor}=="0db0", ATTR{idProduct}=="0076", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0db0", ATTRS{idProduct}=="0076", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="usb", ATTR{idVendor}=="3633", ATTR{idProduct}=="000a", MODE="0660", GROUP="plugdev", TAG+="uaccess"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3633", ATTRS{idProduct}=="000a", MODE="0660", GROUP="plugdev", TAG+="uaccess"
UDEV

udevadm control --reload-rules
udevadm trigger || true

# ------------------------------------------------------------
# 7. Create automatic GPU temperature RGB controller
# Green: below 50 C
# Amber: 50-70 C
# Red: above 70 C
# ------------------------------------------------------------

echo "[7/9] Creating RGB controller..."

cat > "$RGB/rgb-runner.sh" <<'RGB'
#!/usr/bin/env bash
set -u

while true; do
    TEMP="$(
        nvidia-smi \
            --query-gpu=temperature.gpu \
            --format=csv,noheader,nounits 2>/dev/null |
        head -n 1 |
        tr -d '[:space:]' || true
    )"

    if [[ ! "$TEMP" =~ ^[0-9]+$ ]]; then
        logger -t gpu-rgb \
            "Unable to read GPU temperature; will retry."
        sleep 10
        continue
    fi

    if (( TEMP < 50 )); then
        R=0
        G=255
        B=0
    elif (( TEMP <= 70 )); then
        R=255
        G=180
        B=0
    else
        R=255
        G=0
        B=0
    fi

    if ! /opt/gpu-rgb/venv/bin/python \
        /opt/gpu-rgb/rgb-placa.py \
        "$R" "$G" "$B" temporal; then
        logger -t gpu-rgb "RGB update failed at ${TEMP}C."
    fi

    sleep 5
done
RGB

chmod 0755 "$RGB/rgb-runner.sh"

# ------------------------------------------------------------
# 8. Create persistent LCD runner and systemd services
# ------------------------------------------------------------

echo "[8/9] Creating permanent systemd services..."

cat > "$LCD/lcd-runner.sh" <<'LCDRUN'
#!/usr/bin/env bash
set -u

while true; do
    /opt/deepcool/deepcool-digital-linux --pid 10 --update 1000
    RESULT=$?

    echo "DeepCool LCD exited ($RESULT); retrying in 5 seconds."
    sleep 5
done
LCDRUN

chmod 0755 "$LCD/lcd-runner.sh"

cat > /etc/systemd/system/gpu-rgb-control.service <<'RGBUNIT'
[Unit]
Description=GPU Temperature RGB Controller
After=multi-user.target

[Service]
Type=simple
ExecStart=/opt/gpu-rgb/rgb-runner.sh
User=root
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
RGBUNIT

cat > /etc/systemd/system/deepcool-lcd.service <<'LCDUNIT'
[Unit]
Description=DeepCool LD-Series LCD Controller
After=systemd-udev-settle.service
Wants=systemd-udev-settle.service

[Service]
Type=simple
ExecStart=/opt/deepcool/lcd-runner.sh
User=root
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
LCDUNIT

# ------------------------------------------------------------
# 9. Test devices and start services
# ------------------------------------------------------------

echo "[9/9] Checking hardware..."

lsusb | grep -Ei '0db0:0076|3633:000a' || {
    echo "WARNING: One or more expected USB devices were not detected."
}

echo "Testing RGB controller..."

if ! "$RGB/venv/bin/python" "$RGB/rgb-placa.py" \
    0 255 0 temporal; then
    echo "WARNING: RGB test failed. Check hardware compatibility."
fi

echo "Reloading systemd and enabling services..."

systemctl daemon-reload

systemctl enable gpu-rgb-control.service deepcool-lcd.service

systemctl restart gpu-rgb-control.service
systemctl restart deepcool-lcd.service

echo
echo "============================================================"
echo " SETUP FINISHED"
echo "============================================================"
echo
echo "Service configuration:"
systemctl is-enabled gpu-rgb-control.service
systemctl is-enabled deepcool-lcd.service

echo
echo "Service status:"
systemctl is-active gpu-rgb-control.service || true
systemctl is-active deepcool-lcd.service || true

echo
echo "RGB logs:"
echo "sudo journalctl -u gpu-rgb-control.service -f"
echo
echo "LCD logs:"
echo "sudo journalctl -u deepcool-lcd.service -f"
echo
echo "Setup complete. Returning to the normal terminal."
