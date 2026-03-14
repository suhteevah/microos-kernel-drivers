---
title: "Running NVIDIA Maxwell GPUs with CUDA 13.0 on an Immutable Linux OS (openSUSE Leap Micro 6.2)"
published: false
description: "How to build kernel modules on an immutable Linux distro, get a 2014 GPU running modern CUDA workloads, and set up distributed LLM inference across 3 GPUs"
tags: linux, nvidia, cuda, llm
cover_image:
canonical_url: https://github.com/suhteevah/microos-kernel-drivers
---

## The Problem Nobody Talks About

NVIDIA Maxwell GPUs (GTX 900 series, 2014) are widely assumed to be "too old" for modern CUDA. The open-source `nvidia-open` driver only supports RTX 20-series and newer. Distro packages are built against different kernels. Most guides just say "buy a newer card."

**We didn't have that luxury.** We had a GTX 980 in a headless server running openSUSE Leap Micro 6.2 — an immutable OS with a read-only root filesystem, transactional updates, and btrfs snapshots. We needed CUDA working for distributed LLM inference.

Here's what we learned after weeks of figuring it out.

## What Makes Leap Micro Hard

Leap Micro is designed for containers and edge computing. It's incredibly stable, but building kernel modules is genuinely difficult:

- **Read-only root** — you can't just `make install` kernel modules
- **Transactional updates** — every package install creates a btrfs snapshot requiring a reboot
- **Missing packages** — `kernel-default-devel` isn't in the repos
- **SUSE-patched kernel** — struct modifications break modules built against vanilla source
- **SELinux enforcing** — blocks loading unsigned out-of-tree modules from systemd services
- **Subvolume isolation** — `/var/tmp/` and `/usr/local/` are separate subvolumes invisible inside snapshots

### The Subvolume Trap

This one caught us for days. When you run `transactional-update`, it creates snapshots of the root subvolume only. Files in `/var/tmp/` don't exist inside the snapshot. So when you download the NVIDIA installer to `/var/tmp/` and try to run it via `tukit call`... it's not there.

**The fix**: Copy files into the snapshot directly at `/.snapshots/N/snapshot/usr/share/`.

## The Solution

### NVIDIA 580.x Branch + `.run` Installer

The 580.x proprietary driver branch is the last to support Maxwell. The `.run` installer compiles kernel modules against YOUR running kernel — it doesn't care about package versions.

```bash
# Download the driver
curl -o /var/tmp/NVIDIA-Linux-x86_64-580.126.09.run \
  https://us.download.nvidia.com/XFree86/Linux-x86_64/580.126.09/NVIDIA-Linux-x86_64-580.126.09.run

# Open a writable snapshot
tukit open  # Returns snapshot number, e.g., 30

# Copy installer INTO the snapshot
cp /var/tmp/NVIDIA-Linux-x86_64-580.126.09.run /.snapshots/30/snapshot/usr/share/

# Install inside the snapshot
tukit call 30 /usr/share/NVIDIA-Linux-x86_64-580.126.09.run \
  --silent --no-x-check --no-nouveau-check --no-cc-version-check \
  --kernel-source-path=/usr/src/linux-6.12.0-160000.6 \
  --kernel-output-path=/usr/src/linux-6.12.0-160000.6-obj/x86_64/default

tukit close 30
reboot
```

After reboot: `nvidia-smi` shows CUDA 13.0 on the GTX 980. 🎉

### DKMS for Kernel Update Survival

Here's another MicroOS gotcha: `dkms install` **fails on the live system** because `/lib/modules/` is read-only. This is expected! DKMS installs happen automatically inside writable snapshots during `transactional-update` kernel updates via the kernel-install hook.

```bash
dkms add -m nvidia -v 580.126.09
dkms build -m nvidia -v 580.126.09 -k $(uname -r)
# dkms install will fail — that's fine, the hook handles it
```

## The Payoff: 3-GPU Distributed LLM Inference

We use this GTX 980 as a CUDA-accelerated RPC worker in a distributed llama.cpp cluster:

| Machine | GPU | VRAM |
|---------|-----|------|
| Desktop | RTX 3070 Ti | 8 GB |
| Laptop | RTX 3050 | 6 GB |
| **This server** | **GTX 980** | **4 GB** |
| **Total** | | **18 GB** |

Running Qwen2.5-7B across all three GPUs: **21.1 tokens/sec generation**, 16K context window. Not bad for a card that's over a decade old.

## We Also Got WiFi Working

Same server, same challenges. A TP-Link USB WiFi adapter (RTL8821AU) needed the lwfinger/rtw88 driver. That required solving SUSE kernel ABI incompatibilities — specifically, `struct module` has 64 bytes of extra padding from `CONFIG_LIVEPATCH_IPA_CLONES`, and `struct usb_host_endpoint` has 8 extra bytes from a SUSE backport. Without patching these, modules either fail to load or cause data corruption.

## Full Documentation

We open-sourced everything:

**[github.com/suhteevah/microos-kernel-drivers](https://github.com/suhteevah/microos-kernel-drivers)**

- Complete NVIDIA Maxwell guide with CUDA + llama.cpp setup
- Complete RTL8821AU WiFi guide (8 chapters + troubleshooting)
- MicroOS fundamentals: snapshots, subvolumes, DKMS, SELinux
- SUSE kernel ABI compatibility patches

If you're running Leap Micro and need out-of-tree kernel modules, this will save you weeks.

---

*Matt Gates / [Ridge Cell Repair LLC](https://ridgecellrepair.com) — built during the [OpenClaw](https://github.com/suhteevah) project, a distributed AI agent fleet.*
