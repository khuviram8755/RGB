#!/usr/bin/env python3
import time
import torch

DURATION = 60
STOP_TEMP_C = 80
MATRIX_SIZE = 2048

if not torch.cuda.is_available():
    raise SystemExit(
        "CUDA is unavailable. Check the NVIDIA driver and PyTorch installation."
    )

device = torch.device("cuda:0")
print("GPU:", torch.cuda.get_device_name(0))
print(f"Duration: {DURATION}s; temperature stop limit: {STOP_TEMP_C}°C")

a = torch.randn(MATRIX_SIZE, MATRIX_SIZE, device=device)
b = torch.randn(MATRIX_SIZE, MATRIX_SIZE, device=device)

deadline = time.monotonic() + DURATION
last_report = 0

try:
    while time.monotonic() < deadline:
        # Generate real GPU compute load.
        c = torch.mm(a, b)
        torch.cuda.synchronize()

        now = time.monotonic()
        if now - last_report >= 2:
            temp = torch.cuda.temperature() if hasattr(
                torch.cuda, "temperature"
            ) else None

            print(
                f"GPU utilization/temperature: "
                f"check with nvidia-smi | temperature={temp}"
            )
            last_report = now

            if temp is not None and temp >= STOP_TEMP_C:
                print("Temperature limit reached. Stopping.")
                break

except KeyboardInterrupt:
    print("\nTest stopped by user.")

finally:
    del a, b
    if "c" in locals():
        del c
    torch.cuda.empty_cache()
    print("GPU workload stopped.")

