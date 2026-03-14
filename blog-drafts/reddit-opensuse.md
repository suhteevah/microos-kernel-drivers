# r/openSUSE Post

**Title:** Guide: Building out-of-tree kernel modules on Leap Micro 6.2 (NVIDIA Maxwell + WiFi)

**Subreddit:** r/openSUSE (also crosspost to r/linuxhardware, r/homelab, r/LocalLLaMA)

---

I spent a few weeks getting an NVIDIA GTX 980 and a USB WiFi adapter working on Leap Micro 6.2 and documented everything. The existing documentation for building kernel modules on MicroOS is... sparse, so hopefully this helps someone.

**What's covered:**

- Getting kernel source on Leap Micro (the kernel-source package from Leap 16.0 repo works since they share the same 6.12.0-160000.x kernel)
- NVIDIA 580.x proprietary driver installation via `.run` installer inside `tukit` snapshots
- SUSE kernel ABI patches (the 64-byte `struct module` padding from `CONFIG_LIVEPATCH_IPA_CLONES` and the `struct usb_host_endpoint` eUSB2 backport)
- DKMS on immutable root (why `dkms install` fails and why that's fine)
- lwfinger/rtw88 WiFi driver build + boot persistence with systemd services
- SELinux vs `insmod` from systemd context
- The subvolume trap (`/var/tmp/` not visible in snapshots)
- Building llama.cpp with CUDA for Maxwell (compute capability 5.2) for distributed inference

**Repo:** https://github.com/suhteevah/microos-kernel-drivers

Key gotchas that aren't documented anywhere I could find:

1. Files in `/var/tmp/` are NOT visible inside `transactional-update` or `tukit` chroots (separate btrfs subvolume). Copy files to `/.snapshots/N/snapshot/usr/share/` instead.
2. `kernel-default-devel` isn't in Leap Micro repos, but the Leap 16.0 OSS repo has the matching `kernel-source` package.
3. `dkms install` fails on the live system because `/lib/modules/` is read-only — the kernel-install hook handles this during `transactional-update` kernel updates.
4. SELinux blocks `insmod` from systemd services (confined `init_t` domain) even though it works fine from SSH (`unconfined_t`).

The NVIDIA guide includes a full llama.cpp distributed inference setup using the GTX 980 as a CUDA RPC worker alongside an RTX 3070 Ti and RTX 3050 — 18GB total VRAM, running 7B models at 21 tok/s.

Hope this helps someone avoid the weeks of debugging we went through.
