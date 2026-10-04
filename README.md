# beat-runpod — a prebuilt Boundary Lab + BEAT Engine image for RunPod GPU pods

**What it is.** A Docker image with all of these installed at build time, under `/opt`:
- Julia 1.12.6 (x86_64);
- Boundary Lab at `bb9030c4ae0b5906569b3b3932e221a0c97670ac`, with `0001-pin-beat-engine-ti1.patch` (BEAT Engine pin
  0.2.0 → fork release 0.3.0+ti1) and `0002-transfer-impedance-layer.patch` applied;
- the venv;
- the precompiled Julia depot for both BEAT backends, CPU and CUDA.

**Why.** A pod from this image is ready to solve once sshd is up. Before it, a setup script installed all of this on
every empty volume, which took about 17–20 minutes, mostly Julia precompile on a network volume. Measured
2026-10-04: `POST /pods` → ssh in 127 s, CUDA `doctor` 27 s, no install step (`../README.md`).

| File | What |
|---|---|
| `Dockerfile` | The image. Every non-obvious line has its source in a comment. |
| `start.sh` | The container's start command. It writes the env to `/etc/environment` for ssh sessions, starts sshd with `PUBLIC_KEY`, then runs `sleep infinity` under tini. |
| `.github/workflows/build.yml` | On every push to `main`: build, then push `ghcr.io/<owner>/beat-runpod:<sha>` and `:latest`. |
| `make-template.sh` | Creates or updates the RunPod pod template through the REST API. |
| `0001-*.patch`, `0002-*.patch` | Hard links (in the studio repo) to `tools/boundary-lab/`, the single source. |

## Layout inside the image

| Path | What |
|---|---|
| `/opt/julia-1.12.6/` | Julia. `julia` is symlinked into `/usr/local/bin`. |
| `/opt/boundary-lab/` | The clone, patched in the working tree. |
| `/opt/blab-venv/` | The venv. `blab` is symlinked into `/usr/local/bin`. |
| `/opt/julia-depot/` | `JULIA_DEPOT_PATH`. Holds the CPU and CUDA environments, the CUDA 12.8 runtime artifacts and the precompile caches. |
| `/opt/beat-cpu-doctor.json` | The CPU worker's `doctor` output from build time. |

**Environment variables baked in:**
- `JULIA_CPU_TARGET=generic`;
- `OPENBLAS_NUM_THREADS=8` and `OMP_NUM_THREADS=8`, because inside the pod `nproc` reports the host's cores, not the
  ~9 vCPU it is allotted;
- `JULIA_PKG_OFFLINE=true`.

The network volume (if any) still mounts at `/workspace` and is only for jobs.

## CUDA without a GPU at build time

CUDA.jl picks its runtime artifact when it precompiles. Without a driver it picks none, downloads nothing, and the
build cannot run GPU code. Pinning the runtime version with `CUDA.set_runtime_version!(v"12.8")` makes that choice
independent of the driver. The next `using CUDA` then downloads and precompiles that runtime, and
`CUDA.precompile_runtime()` precompiles GPUCompiler's device library too.
(https://cuda.juliagpu.org/stable/installation/overview/, section "Precompiling CUDA.jl without CUDA".)

- **Upstream's script.** Boundary Lab ships exactly this as `docker/prepare_cuda.py` at the pinned commit. The
  Dockerfile runs that script rather than a copy of it.
- **Driver requirement.** The chosen version has to be one the pod's driver supports. CUDA 12.8 needs driver
  >= 570.26.
- **Enforced at container start.** The base image's `NVIDIA_REQUIRE_CUDA=cuda>=12.8` makes the NVIDIA container
  toolkit refuse an older host, so the failure is loud.
- **Proof in the build.** The build fails unless `libcublas.so.12*` and `libcudss.so*` are in the depot.

## Size (estimate from before the first build)

Measured on the first pod: `du -sh /opt` = 5.7 GB; the pull and extract took about 90 s.


| Layer | Compressed (pushed) | Uncompressed | Source of the number |
|---|---|---|---|
| `nvidia/cuda:12.8.2-base-ubuntu24.04` | 35 MB | ~90 MB | Docker Hub tag API |
| apt (python3, git, openssh, X libs, tini) | ~120 MB | ~350 MB | guess |
| Julia 1.12.6 | 290 MB | 1.1 GB | tarball length; local `du` |
| Boundary Lab clone | ~60 MB | 156 MB | local `du` |
| venv | ~350 MB | ~1.0 GB | local `du` (arm64 venv) |
| Julia depot, CPU + CUDA | ~2.2 GB | ~5 GB | CUDA_Runtime 12.8 artifact 1525 MB, CUDA_Driver 153 MB and cuDSS 109 MB (GitHub release assets); 5 GB is the measured volume depot (`tools/runpod/README.md`) |
| **Total** | **~3 GB** | **~8 GB** | |

**The runtime base is not used.** The `-runtime-` base (2087 MB compressed) would add ~2 GB to every pull for CUDA
libraries CUDA.jl never loads.

**It fits the free runner.** `ubuntu-latest` has 14 GB nominal. Peak need is about the extracted layers plus their
compressed copies during push, ~12 GB. The free-disk step removes Android, .NET, GHC and CodeQL, which frees roughly
25–30 GB more.

## Build

1. Make this folder its own GitHub repo and push to `main`.
2. Actions runs `build.yml` (about 30–40 min the first time; the registry cache makes start.sh-only changes quick).
3. GHCR → the package `beat-runpod` → Package settings → change visibility to **Public**. Otherwise RunPod needs a
   registry credential (`containerRegistryAuthId`).
   (https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)

## Template

    ./make-template.sh ghcr.io/<owner>/beat-runpod:<sha>

- **First run.** It creates the template and saves its id in `/workspace/.secrets/runpod_template_id`.
- **Later runs.** They PATCH that template to the new image.
- **The key.** It is read only from `/workspace/.secrets/runpod_api_key` and passed to curl through a header file,
  never through argv.
- **No `PUBLIC_KEY` in the template.** RunPod sets it in every pod from the account's SSH keys, and a pod-level
  `PUBLIC_KEY` replaces it.

## How the studio `pod.sh` uses it

`pod.sh create` passes `templateId` (from `runpod_template_id`) and `"allowedCudaVersions": ["12.8", "12.9", "13.0"]`
(https://docs.runpod.io/api-reference/pods/POST/pods.md), plus the GPU list, datacenter and network volume. The
network volume holds only jobs. `run-job.sh` calls `/opt/julia-1.12.6/bin/julia` and sources nothing. See
`../README.md`.

## Open questions — first build and first pod answered most of them (2026-10-04)

1. ~~does the depot need nothing at pod start?~~ **Answered 2026-10-04 (RTX 4090, driver 570.211.01):** yes. The
   CUDA `doctor` printed no download and no "Precompiling" line (27.0 s first call, 26.9 s second,
   `"available": true`), and neither did the 18-frequency coupled solve.
2. **UNVERIFIED: does `JULIA_PKG_OFFLINE=true` make a missing lazy artifact fail?** Not exercised: on the first pod
   nothing was missing.
3. ~~is the cache valid at run time?~~ **Answered 2026-10-04:** yes. The blab worker's solve recompiled nothing: no
   "Precompiling" in `solve.log`, every `.so` in `compiled/` kept its build mtime, and `/` (the container layer) grew
   by 2 MB. Julia does rewrite the mtime of the `.ji` files it loads (12 of them), which is not a recompile.
4. ~~gmsh system libraries~~ **Answered 2026-10-04:** the first build failed at `import gmsh` with
   `libGL.so.1: cannot open shared object file`; the apt list is now the full `ldd libgmsh.so` set (see the
   Dockerfile comment).
5. ~~does sshd see the env, and does `PUBLIC_KEY` arrive?~~ **Answered 2026-10-04:** yes to both. `ssh pod env`
   (non-interactive) showed `JULIA_DEPOT_PATH=/opt/julia-depot`, `JULIA_CPU_TARGET`, `JULIA_PKG_OFFLINE`,
   `OPENBLAS_NUM_THREADS`, `OMP_NUM_THREADS` and `RUNPOD_POD_ID` (29 lines in `/etc/environment`). With no
   `PUBLIC_KEY` in the template or the pod request, RunPod injected the account's 5 keys and ssh worked.
6. ~~does pod start meet ~1 minute?~~ **Answered 2026-10-04:** no, about 2. Container start (pull + extract) 93 s
   after `POST /pods`, ssh 127 s. One sample, on a host that had probably not cached the image.
7. ~~does the image count against `containerDiskInGb` (30)?~~ **Answered 2026-10-04:** no. `/` showed 30 GB size with
   16 MB used while `/opt` held 5.7 GB.
8. ~~does the GitHub runner build fit?~~ **Answered 2026-10-04:** yes, run 37218910088 built and pushed it (its
   `df -h` and duration were not read). That covered the disk peak and the time a 4-vCPU runner takes for
   the CUDA precompile (`timeout-minutes: 120`). The workflow logs `df -h` before and after.
9. **UNVERIFIED: is CUDA 12.8 the right runtime pin?** It is upstream's choice. The runtime pin and the base tag
   (12.8.2) must move together. A lower pin (e.g. 12.4) would admit older-driver hosts. A higher one would need
   `allowedCudaVersions` changed with it.
10. **UNVERIFIED: is `JULIA_CPU_TARGET=generic` costing speed?** It matches today's pod and upstream. Julia's
    multi-target string (generic plus haswell plus x86-64-v4 clones) might speed up the CPU paths at the cost of a
    larger depot. Not measured.
