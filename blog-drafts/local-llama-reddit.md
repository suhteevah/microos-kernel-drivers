# r/LocalLLaMA Post

**Title:** GTX 980 (2014) running CUDA 13.0 + llama.cpp distributed inference at 21 tok/s — full guide for getting Maxwell GPUs working on modern Linux

---

Everyone says Maxwell is "too old for AI." I've been running a GTX 980 as a CUDA RPC worker in a 3-GPU distributed llama.cpp cluster for over a month now and it works great.

**Setup:**
- RTX 3070 Ti (8GB) — runs llama-server + RPC worker
- RTX 3050 (6GB) — RPC worker
- GTX 980 (4GB) — RPC worker on headless Linux server
- Total: 18GB VRAM distributed

**Results (Qwen2.5-7B-Instruct Q4_K_M):**
- Generation: 21.1 tok/s
- Prompt processing: 57.3 tok/s
- Context: 16,384 tokens
- VRAM usage: 3070 Ti 4823MB, 980 1451MB, 3050 ~1200MB

**What it took:**
The server runs openSUSE Leap Micro 6.2 (immutable OS). Getting NVIDIA working required:
1. NVIDIA 580.x proprietary driver (.run installer — the ONLY option for Maxwell on modern kernels)
2. Building inside btrfs snapshots (immutable root filesystem)
3. CUDA 12.8 toolkit + GCC 13 as host compiler
4. `CMAKE_CUDA_ARCHITECTURES=52` for Maxwell compute capability
5. `GGML_RPC=ON` (off by default in llama.cpp)

I documented the entire process including the nasty MicroOS-specific gotchas:

**Repo:** https://github.com/suhteevah/microos-kernel-drivers

The NVIDIA guide covers everything from driver installation through building llama.cpp with CUDA + RPC support, plus a systemd service for auto-starting the RPC worker.

If you have an old Maxwell card collecting dust, it can still contribute VRAM to a distributed inference cluster. Don't throw it away.
