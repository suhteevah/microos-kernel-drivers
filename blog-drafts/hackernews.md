# Hacker News Submission

**Title:** Building Kernel Modules on Immutable Linux (openSUSE Leap Micro) – NVIDIA, WiFi, DKMS, CUDA

**URL:** https://github.com/suhteevah/microos-kernel-drivers

**Comment (Show HN style):**

We run a distributed LLM inference cluster across 3 GPUs (RTX 3070 Ti + RTX 3050 + GTX 980). The GTX 980 sits in a headless server running openSUSE Leap Micro 6.2 — an immutable OS designed for containers.

Getting NVIDIA CUDA working on an immutable distro with a 2014 GPU was... an adventure. The documentation basically doesn't exist. We solved it and wrote up everything:

- How to get kernel source on Leap Micro (Leap 16.0 repo compatibility trick)
- NVIDIA `.run` installer inside `tukit` snapshots
- SUSE kernel ABI patches (struct padding that breaks module loading)
- DKMS on read-only root
- RTL8821AU WiFi driver (lwfinger/rtw88) with boot persistence
- SELinux vs out-of-tree modules
- The btrfs subvolume trap

The GTX 980 runs CUDA 13.0 with the NVIDIA 580.x driver and does distributed llama.cpp inference at 21 tok/s on 7B models. Not bad for hardware from 2014.

MIT licensed, PRs welcome.
