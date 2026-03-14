# Running NVIDIA Maxwell GPUs (GTX 900 Series) with Modern Drivers & CUDA on Current Linux Kernels

**TL;DR**: NVIDIA Maxwell GPUs (GTX 980, GTX 970, GTX 960, etc.) work with the latest NVIDIA 580.x proprietary driver on kernel 6.12+, providing CUDA 13.0 support. This enables modern AI/ML workloads like llama.cpp distributed inference on hardware from 2014.

## Why This Matters

Maxwell GPUs (compute capability 5.0-5.2) are widely assumed to be "too old" for modern CUDA workloads. NVIDIA's open-source kernel driver (`nvidia-open` / G06) only supports **Turing and newer** (RTX 20-series+), and the official kmp/dkms packages for many distros are built against older kernels. This leads people to believe Maxwell cards are unsupported on modern kernels.

**They're wrong.** Here's what actually works.

## Supported Hardware

| GPU Family | Architecture | Compute Capability | Example GPUs |
|------------|-------------|-------------------|-------------|
| Maxwell v1 | GM107/GM108 | 5.0 | GTX 750, GTX 750 Ti, GTX 850M, GTX 860M |
| Maxwell v2 | GM200/GM204/GM206 | 5.2 | **GTX 980**, GTX 980 Ti, GTX 970, GTX 960, GTX 950, Titan X (Maxwell), Quadro M6000 |

## The Solution: NVIDIA 580 Branch + Proprietary .run Installer

### Driver Branch

The **NVIDIA 580.x driver branch** is the last to support Maxwell, Pascal, and Volta GPUs. As of March 2026:

- **Driver**: 580.126.09
- **CUDA**: 13.0
- **Kernel support**: Tested working on kernel 6.12.0 (openSUSE Leap Micro 6.2 / Leap 16.0)
- **Download**: [NVIDIA Unix Driver Archive](https://www.nvidia.com/en-us/drivers/unix/) → Latest Long Lived Branch (580.x)

### Why NOT the Open Driver or Packaged kmp/dkms

1. **`nvidia-open` (G06)**: Only supports Turing+ (compute 7.5+). Maxwell is explicitly unsupported.
2. **Distro kmp packages**: Often built against a different kernel version than what you're running. On openSUSE Leap Micro 6.2, the `nvidia-video-G06-kmp-default` package targets kernel 6.4.0 while the running kernel is 6.12.0 — instant mismatch.
3. **The .run installer**: Compiles kernel modules from source against YOUR running kernel. This is the only reliable path for Maxwell on modern kernels.

## Step-by-Step: openSUSE Leap Micro 6.2 (MicroOS / Immutable)

This is the hardest case — an immutable OS with read-only root, transactional updates, and btrfs snapshots. If it works here, it works anywhere.

### Prerequisites

```bash
# Check your kernel version
uname -r
# 6.12.0-160000.6-default

# Check your GPU
lspci | grep -i nvidia
# NVIDIA Corporation GM204 [GeForce GTX 980]
```

### Step 1: Install Kernel Source (Critical!)

The NVIDIA installer needs full kernel headers. On Leap Micro 6.2, `kernel-default-devel` provides the build directory but NOT the full source. The source symlink at `/lib/modules/.../source` is **dangling**.

**Key discovery**: Leap Micro 6.2 shares the same kernel (6.12.0-160000.x) as Leap 16.0. The `kernel-source` package is available from the Leap 16.0 repo:

```bash
# Add Leap 16.0 OSS repo
zypper ar -f 'https://download.opensuse.org/distribution/leap/16.0/repo/oss/' repo-leap16-oss

# Install kernel-source (matches your running kernel)
transactional-update -n pkg install kernel-source-6.12.0-160000.6.1

# Reboot to activate
reboot
```

After reboot, verify: `ls /usr/src/linux-6.12.0-160000.6/include/linux/kernel.h` — this file MUST exist.

### Step 2: Download the NVIDIA 580 Driver

```bash
curl -o /var/tmp/NVIDIA-Linux-x86_64-580.126.09.run \
  https://us.download.nvidia.com/XFree86/Linux-x86_64/580.126.09/NVIDIA-Linux-x86_64-580.126.09.run
```

### Step 3: Install via tukit (MicroOS-specific)

On immutable systems, you can't run the installer directly. Use `tukit` to create a writable snapshot:

```bash
# Get current default snapshot number
snapper list | tail -5

# Open a new snapshot based on current default
tukit -c<CURRENT_SNAPSHOT> open
# Returns new snapshot number, e.g., 30

# Copy the installer INTO the snapshot (important! /var/tmp isn't visible in the chroot)
cp /var/tmp/NVIDIA-Linux-x86_64-580.126.09.run /.snapshots/30/snapshot/usr/share/

# Run the installer inside the snapshot
tukit call 30 /usr/share/NVIDIA-Linux-x86_64-580.126.09.run \
  --silent --no-x-check --no-nouveau-check --no-cc-version-check \
  --kernel-source-path=/usr/src/linux-6.12.0-160000.6 \
  --kernel-output-path=/usr/src/linux-6.12.0-160000.6-obj/x86_64/default

# Close the snapshot
tukit close 30

# Reboot to activate
reboot
```

### Step 4: Verify

```bash
nvidia-smi
# +-----------------------------------------------------------------------------------------+
# | NVIDIA-SMI 580.126.09             Driver Version: 580.126.09     CUDA Version: 13.0     |
# +-----------------------------------------+------------------------+----------------------+
# | NVIDIA GeForce GTX 980                  | 51°C | 74MiB / 4096MiB |
# +-----------------------------------------+------------------------+----------------------+

lsmod | grep nvidia
# nvidia_uvm, nvidia_drm, nvidia_modeset, nvidia
```

### Step 5: Set Up DKMS (Survive Kernel Updates)

```bash
# Install DKMS
transactional-update -n pkg install dkms
reboot

# Register the NVIDIA module (source was placed at /usr/src/nvidia-580.126.09/ by the installer)
dkms add -m nvidia -v 580.126.09

# Build for current kernel
dkms build -m nvidia -v 580.126.09 -k $(uname -r)

# Verify
dkms status
# nvidia/580.126.09, 6.12.0-160000.6-default, x86_64: built
```

The kernel-install hook at `/usr/lib/kernel/install.d/40-dkms.install` will automatically rebuild NVIDIA modules when `transactional-update` installs a new kernel.

## Standard Linux (Non-Immutable)

On regular distros (Ubuntu, Fedora, Arch, standard openSUSE), it's much simpler:

```bash
# Install prerequisites
sudo apt install build-essential linux-headers-$(uname -r) dkms  # Debian/Ubuntu
sudo dnf install kernel-devel kernel-headers gcc make dkms        # Fedora
sudo zypper install kernel-default-devel kernel-source gcc make dkms  # openSUSE

# Run the installer with DKMS
sudo bash NVIDIA-Linux-x86_64-580.126.09.run --dkms

# Verify
nvidia-smi
```

## Real-World Use Case: Distributed LLM Inference with llama.cpp

We use the GTX 980 (4GB VRAM) as a CUDA-accelerated RPC worker in a 3-GPU distributed inference cluster:

| Machine | GPU | VRAM | Role |
|---------|-----|------|------|
| Desktop | RTX 3070 Ti | 8 GB | llama-server + RPC worker |
| Laptop | RTX 3050 | 6 GB | RPC worker |
| Server | **GTX 980** | **4 GB** | **RPC worker (CUDA)** |
| **Total** | | **18 GB** | |

### Building llama.cpp with CUDA for Maxwell

```bash
# Need GCC 13+ for C++17 headers (<filesystem>, <charconv>)
# On openSUSE: zypper install gcc13 gcc13-c++

# Need CUDA toolkit
# Add NVIDIA CUDA repo for SLES15/Leap
zypper ar -f 'https://developer.download.nvidia.com/compute/cuda/repos/sles15/x86_64/' cuda-repo
zypper install cuda-nvcc-12-8 cuda-cudart-devel-12-8 libcublas-devel-12-8

# Clone and build
git clone --depth 1 --branch b8182 https://github.com/ggml-org/llama.cpp.git
cd llama.cpp && mkdir build && cd build

cmake .. \
  -DGGML_CUDA=ON \
  -DGGML_RPC=ON \
  -DCMAKE_C_COMPILER=/usr/bin/gcc-13 \
  -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.8/bin/nvcc \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 \
  -DCMAKE_CUDA_ARCHITECTURES=52 \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_COMMON=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_BUILD_TYPE=Release

cmake --build . --target rpc-server -j$(nproc)
```

**Key cmake flags**:
- `CMAKE_CUDA_ARCHITECTURES=52` — Maxwell (GTX 980) is compute capability 5.2
- `GGML_RPC=ON` — Required! The `rpc-server` target is gated by this flag
- `GGML_CUDA=ON` — Enable CUDA backend
- GCC 13+ required as CUDA host compiler for C++17 `<filesystem>` and `<charconv>` headers

### systemd Service for RPC Worker

```ini
[Unit]
Description=llama.cpp RPC Server (CUDA)
After=network.target

[Service]
Type=simple
Environment=LD_LIBRARY_PATH=/opt/llama/llama-b8182:/usr/local/cuda-12.8/targets/x86_64-linux/lib
ExecStart=/opt/llama/llama-b8182/rpc-server -H 0.0.0.0 -p 50052
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## MicroOS-Specific Gotchas

1. **`/var/tmp/` is a separate btrfs subvolume** — Files there are NOT visible inside `tukit call` or `transactional-update run` chroots. Copy files into the snapshot at `/.snapshots/N/snapshot/usr/share/` instead.

2. **`/usr/local/` is a separate writable subvolume** — Packages installed via `transactional-update` that write to `/usr/local/` (like CUDA toolkit RPMs) put files in `/.snapshots/N/snapshot/usr/local/` but NOT in the live `/usr/local/`. You must manually copy: `cp -a /.snapshots/N/snapshot/usr/local/cuda-12.8 /usr/local/`

3. **Snapshot lineage matters** — `transactional-update` creates new snapshots from the current default. If you have multiple pending snapshots, the warning `"created from a different base"` means changes in one branch won't appear in the other. Always check that critical files (like NVIDIA kernel modules) exist in the new snapshot before rebooting.

4. **`kernel-source` is NOT in Leap Micro repos** — You must add the Leap 16.0 OSS repo to get the matching `kernel-source` package.

5. **`dkms install` fails on live system** — `/lib/modules/` is read-only. DKMS can only `add` and `build` on the live system. The actual `install` step happens automatically during `transactional-update` kernel updates (via the kernel-install hook), where the snapshot root is writable.

## FAQ

**Q: Will NVIDIA drop Maxwell support in future driver branches?**
A: The 580.x branch is specifically designated as the last to support Maxwell/Pascal/Volta. Future branches (590+) will drop these architectures. However, the 580.x branch will continue receiving security and bug fixes as a legacy branch.

**Q: Can I use the open-source `nvidia-open` driver instead?**
A: No. `nvidia-open` only supports Turing (RTX 20-series) and newer. Maxwell requires the proprietary driver.

**Q: What about Nouveau?**
A: Nouveau has basic display support for Maxwell but no CUDA compute capability. For any ML/AI workload, you need the proprietary driver.

**Q: Does this work on kernel 6.x in general?**
A: We've confirmed it on 6.12.0. The .run installer compiles against whatever kernel headers you provide, so it should work on any kernel version that NVIDIA's source code supports. The 580.x branch is actively maintained.

**Q: What CUDA compute capability does Maxwell have?**
A: GM107/GM108 (Maxwell v1) = compute 5.0, GM200/GM204/GM206 (Maxwell v2) = compute 5.2. For llama.cpp, use `CMAKE_CUDA_ARCHITECTURES=52` (or `50` for v1 cards).

---

*Tested March 2026 on openSUSE Leap Micro 6.2 (kernel 6.12.0-160000.6-default) with NVIDIA GeForce GTX 980, driver 580.126.09, CUDA 13.0. Running llama.cpp b8182 distributed inference across 3 GPUs (RTX 3070 Ti + RTX 3050 + GTX 980).*
