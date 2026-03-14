# Building Out-of-Tree Kernel Modules on openSUSE Leap Micro 6.2

**A practitioner's guide to NVIDIA GPU drivers, WiFi drivers, and CUDA workloads on an immutable Linux distribution.**

*Tested March 2026 on openSUSE Leap Micro 6.2 (kernel 6.12.0-160000.6-default)*

---

## Who This Is For

If you're running openSUSE Leap Micro (or SLE Micro) and need hardware that doesn't have in-tree kernel drivers, this guide covers the complete process. We built and deployed two very different out-of-tree drivers on the same system:

1. **NVIDIA 580.126.09 proprietary GPU driver** — for a GTX 980 running CUDA 13.0 + llama.cpp distributed inference
2. **lwfinger/rtw88 WiFi driver** — for a TP-Link Archer T2U PLUS USB adapter (RTL8821AU chipset)

Both required solving the same core set of MicroOS challenges, plus their own hardware-specific quirks.

## Why This Matters

openSUSE Leap Micro is designed for containers and edge computing. The immutable root, transactional updates, and btrfs snapshots make it incredibly stable — but building kernel modules is genuinely hard, and the existing documentation is sparse to nonexistent.

**We spent weeks figuring this out so you don't have to.**

## Guides

| Guide | What It Covers |
|-------|---------------|
| **[nvidia/](nvidia/)** | NVIDIA Maxwell (GTX 900 series) driver on MicroOS + CUDA + llama.cpp distributed inference |
| **[wifi/](wifi/)** | RTL8821AU WiFi driver (lwfinger/rtw88) on MicroOS with boot persistence |
| **[microos-fundamentals.md](microos-fundamentals.md)** | Core MicroOS concepts: snapshots, subvolumes, transactional-update, DKMS, SELinux |

## The Core Challenges

openSUSE Leap Micro 6.2 is an immutable OS. Building kernel modules on it is hard because:

| Challenge | Impact |
|-----------|--------|
| **Read-only root filesystem** | Can't write to `/lib/modules/`, `/usr/`, or install packages normally |
| **Transactional updates** | Every package install creates a btrfs snapshot, requiring a reboot to activate |
| **No kernel-default-devel in repos** | The package that provides kernel build headers isn't in Leap Micro repositories |
| **SUSE-patched kernel** | The 6.12.0-160000.x kernel has SUSE-specific struct modifications not in vanilla source |
| **SELinux enforcing** | Blocks `insmod` from systemd service context (out-of-tree modules aren't signed) |
| **Separate btrfs subvolumes** | `/var/tmp`, `/usr/local`, `/opt`, `/root` are writable but NOT visible inside `transactional-update` or `tukit` chroots |

### The Snapshot/Subvolume Trap

This is the single most confusing aspect of MicroOS for anyone building kernel modules:

- `transactional-update` creates snapshots of the **root subvolume only**
- `/var/tmp/`, `/usr/local/`, `/opt/`, and `/root/` are separate writable subvolumes
- Files in these directories are **NOT copied into snapshots**
- To get files into a snapshot, copy them to `/.snapshots/N/snapshot/usr/share/` (or similar path within the snapshot root)
- Conversely, packages that install files to `/usr/local/` during `transactional-update` put them in `/.snapshots/N/snapshot/usr/local/`, NOT the live `/usr/local/` — you may need to manually copy them after reboot

## Quick Start

### I have an NVIDIA Maxwell GPU

→ Go to **[nvidia/README.md](nvidia/README.md)**

### I have a USB WiFi adapter (RTL8821AU)

→ Go to **[wifi/README.md](wifi/README.md)**

### I just want to understand MicroOS kernel module building

→ Read **[microos-fundamentals.md](microos-fundamentals.md)** first

## Hardware Used

| Component | Model | Purpose |
|-----------|-------|---------|
| Server | Intel i7-4790K, 32GB RAM | Build host |
| GPU | NVIDIA GeForce GTX 980 (4GB) | CUDA compute worker |
| WiFi | TP-Link Archer T2U PLUS (RTL8821AU) | USB WiFi adapter |
| OS | openSUSE Leap Micro 6.2 | Immutable container host |
| Kernel | 6.12.0-160000.6-default | SUSE-patched kernel |

## Real-World Use Case

We use this server as part of a 3-GPU distributed LLM inference cluster running llama.cpp:

| Machine | GPU | VRAM | Role |
|---------|-----|------|------|
| Desktop (Windows) | RTX 3070 Ti | 8 GB | llama-server + RPC worker |
| Laptop (Windows) | RTX 3050 | 6 GB | RPC worker |
| **This server** (Leap Micro) | **GTX 980** | **4 GB** | **RPC worker (CUDA)** |
| **Total** | | **18 GB** | Distributed inference |

The GTX 980 is a 2014 GPU that most people assume is "too old" for AI workloads. It's not.

## Contributing

Found an issue? Have a different hardware combination? PRs welcome. This guide is a living document.

## License

MIT. Use it, share it, adapt it.

---

*By Matt Gates / Ridge Cell Repair LLC — built during the [OpenClaw](https://github.com/suhteevah) project.*
