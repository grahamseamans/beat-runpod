# beat-runpod — a prebuilt Boundary Lab + BEAT Engine image for RunPod GPU pods

**What it is.** A Docker image with all of these installed at build time, under `/opt`:
- Julia 1.12.6 (x86_64);
- Boundary Lab at `bb9030c4ae0b5906569b3b3932e221a0c97670ac`, with `beat-engine-0.3.0.patch` applied (it moves the
  BEAT Engine pin from 0.2.0 to 0.3.0);
- the venv;
- the precompiled Julia depot for both BEAT backends, CPU and CUDA.

**Why.** A pod from this image is ready to solve once sshd is up. Before it, `setup-pod.sh` had to install all of
this on every empty volume, which took about 17–20 minutes, mostly Julia precompile on a network volume.

| File | What |
|---|---|
| `Dockerfile` | The image. Every non-obvious line has its source in a comment. |
| `start.sh` | The container's start command. It writes the env to `/etc/environment` for ssh sessions, starts sshd with `PUBLIC_KEY`, then runs `sleep infinity` under tini. |
| `.github/workflows/build.yml` | On every push to `main`: build, then push `ghcr.io/<owner>/beat-runpod:<sha>` and `:latest`. |
| `make-template.sh` | Creates or updates the RunPod pod template through the REST API. |
| `beat-engine-0.3.0.patch` | A copy of the studio repo's `tools/boundary-lab/beat-engine-0.3.0.patch`, which is the single source. Delete it when upstream Boundary Lab pins BEAT Engine 0.3.0 itself. |

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

## Size (estimate; no build has run yet)

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

## How the studio `pod.sh` would use it (not changed here)

**In `pod.sh create`:**
- `IMAGE` becomes `ghcr.io/<owner>/beat-runpod:<sha>`. Pin the sha, not `:latest`.
- Alternatively, pass `templateId` from `runpod_template_id`.
- Add `"allowedCudaVersions": ["12.8", "12.9", "13.0"]` so RunPod only places the pod on hosts whose driver runs
  CUDA 12.8 (https://docs.runpod.io/api-reference/pods/POST/pods.md). Without it, an old-driver host fails at
  container start.

**Retired:**
- `setup-pod.sh` and the volume's Julia, clone, venv and depot. The network volume is then needed only for job files
  and could be dropped for plain `rsync` in and out.

**`env.sh` and `run-job.sh`:**
- Paths change from `/workspace/julia-1.12.6/bin/julia` to `/opt/julia-1.12.6/bin/julia`, or just `julia`.
- The env vars are already set in every ssh session, so sourcing `env.sh` becomes unnecessary.

## Open questions — could not be verified without a build or a pod

1. **UNVERIFIED: does the depot need nothing at pod start?** The build-time checks prove cuBLAS and cuDSS are in the
   depot. They do not prove that no other lazy artifact (for example, one selected on the real GPU's compute
   capability) or precompile cache is missed.
   - First pod: run `python -m beat_engine --backend cuda doctor` and watch for downloads or "Precompiling".
2. **UNVERIFIED: does `JULIA_PKG_OFFLINE=true` make a missing lazy artifact fail?** It is wanted to fail loudly.
   Pkg's docs only say it "tries to do as much as possible without connecting". If it still downloads, the offline
   flag is not the guard.
3. **UNVERIFIED: is the cache valid at run time?** The precompile cache is keyed on the CPU target, the Julia flags
   and the preferences. It should be identical at run time (same ENV, same `LocalPreferences.toml`), but if blab's
   worker passes a codegen-affecting flag, packages recompile at the first solve. That would cost minutes, not the
   ~60 s of Julia start and CUDA JIT seen today.
4. ~~gmsh system libraries~~ **Answered 2026-10-04:** the first build failed at `import gmsh` with
   `libGL.so.1: cannot open shared object file`; the apt list is now the full `ldd libgmsh.so` set (see the
   Dockerfile comment).
5. **UNVERIFIED: does sshd see the env, and does `PUBLIC_KEY` arrive?**
   - `ssh pod env | grep JULIA` should show the baked vars, through `/etc/environment` and pam_env.
   - Check that RunPod really injects `PUBLIC_KEY` for a custom image (its docs list it as Runpod-provided).
6. **UNVERIFIED: does pod start meet ~1 minute?** It depends on how fast RunPod pulls ~3 GB from GHCR and extracts
   ~8 GB, and on whether hosts cache the image. Measure `create` → ssh up on the first pods.
7. **UNVERIFIED: does the image count against `containerDiskInGb` (30)?** If it does, 30 GB still leaves ~22 GB.
8. **UNVERIFIED: does the GitHub runner build fit?** That covers the disk peak and the time a 4-vCPU runner takes for
   the CUDA precompile (`timeout-minutes: 120`). The workflow logs `df -h` before and after.
9. **UNVERIFIED: is CUDA 12.8 the right runtime pin?** It is upstream's choice. The runtime pin and the base tag
   (12.8.2) must move together. A lower pin (e.g. 12.4) would admit older-driver hosts. A higher one would need
   `allowedCudaVersions` changed with it.
10. **UNVERIFIED: is `JULIA_CPU_TARGET=generic` costing speed?** It matches today's pod and upstream. Julia's
    multi-target string (generic plus haswell plus x86-64-v4 clones) might speed up the CPU paths at the cost of a
    larger depot. Not measured.
