# syntax=docker/dockerfile:1
# Boundary Lab + BEAT Engine 0.3.0, CPU and CUDA backends, fully installed at build time, for RunPod GPU pods.
# x86_64 only. A pod from this image is ready to solve once sshd is up: nothing is installed or downloaded at start.
#
# Everything lives under /opt, never /workspace: RunPod mounts the pod's (network) volume at /workspace, which would
# hide anything baked there. https://docs.runpod.io/api-reference/templates/POST/templates.md (volumeMountPath)

# ---- base ----------------------------------------------------------------------------------------------------------
# `base`, not `runtime`: CUDA.jl downloads its own CUDA runtime as Julia artifacts and does not load a system toolkit
# unless told to (local_toolkit=true), so the runtime variant's CUDA libraries would sit unused next to CUDA.jl's copy.
#   https://cuda.juliagpu.org/stable/installation/overview/  ("CUDA toolkit": artifacts are the recommended default)
#   CUDA.jl's own image builds on plain `julia:` for the same reason: https://github.com/JuliaGPU/CUDA.jl/blob/master/Dockerfile
# Sizes (amd64, compressed, hub.docker.com/v2/repositories/nvidia/cuda/tags): 12.8.2-base-ubuntu24.04 35 MB,
# 12.8.2-runtime-ubuntu24.04 2087 MB.
# What `base` still carries, and what we need from it (read from the image config, 2026-10-04):
#   NVIDIA_VISIBLE_DEVICES=all, NVIDIA_DRIVER_CAPABILITIES=compute,utility -> the NVIDIA container toolkit injects
#   libcuda and nvidia-smi at run time (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/docker-specialized.html)
#   NVIDIA_REQUIRE_CUDA=cuda>=12.8 (+ datacenter-driver brand clauses) -> the toolkit REFUSES to start the container on a
#   host whose driver is older than CUDA 12.8. That is the same floor as the CUDA 12.8 runtime baked below, so an
#   unsuitable host fails loudly at container start instead of at the first solve.
ARG BASE_IMAGE=nvidia/cuda:12.8.2-base-ubuntu24.04@sha256:b382332b575435b081b805b15b3aa1779a350a4e513f4d0449b4d7ad098e94ff
FROM --platform=linux/amd64 ${BASE_IMAGE}

ARG JULIA_VERSION=1.12.6
# Boundary Lab upstream main on 2026-10-03 (merge of feat/interface-radiation). Same pin as the studio repo's
# tools/runpod/setup-pod.sh and .devcontainer/Dockerfile.
ARG BLAB_COMMIT=bb9030c4ae0b5906569b3b3932e221a0c97670ac
ARG BEAT_ENGINE_VERSION=0.3.0

# JULIA_CPU_TARGET=generic: what Boundary Lab's own Dockerfile sets, so the precompiled package images load on any
#   x86_64 host CPU (RunPod hands out whatever host the GPU sits in).
#   https://github.com/JWSound/boundary-lab/blob/bb9030c4ae0b5906569b3b3932e221a0c97670ac/Dockerfile
#   https://docs.julialang.org/en/v1/manual/environment-variables/#JULIA_CPU_TARGET
# OPENBLAS_NUM_THREADS / OMP_NUM_THREADS=8: inside a RunPod container nproc reports the HOST's cores (96 seen) while
#   the cgroup allots ~9 vCPU. OpenBLAS sizes its pool from the host count; the coupled FEM/Schur step then took
#   >22 min on one frequency instead of ~1 min (measured 2026-10-03, studio repo tools/runpod/README.md).
#   https://github.com/OpenMathLib/OpenBLAS/wiki/Faq#how-can-i-use-openblas-in-multi-threaded-applications
# These ENV lines reach `docker exec` shells only; ssh sessions get them through /etc/environment, see start.sh.
ENV JULIA_DEPOT_PATH=/opt/julia-depot \
    JULIA_CPU_TARGET=generic \
    OPENBLAS_NUM_THREADS=8 \
    OMP_NUM_THREADS=8 \
    PYTHONUNBUFFERED=1 \
    MPLBACKEND=Agg \
    DEBIAN_FRONTEND=noninteractive

# ---- system packages -----------------------------------------------------------------------------------------------
# openssh-server: RunPod's "full SSH" (scp/rsync over the public IP) needs sshd running inside the container.
#   https://docs.runpod.io/pods/configuration/use-ssh.md ("Full SSH via public IP with key authentication")
# rsync: the job upload/download path (rsync -rt). procps: run-job.sh samples `ps`.
# tini: PID 1 that reaps zombies. Solves are started with nohup from ssh sessions that then exit, so finished solves
#   are reparented to PID 1; `sleep infinity` would never reap them. Boundary Lab's own image uses tini too.
#   https://github.com/krallin/tini#why-tini
# libgl1/libglu1-mesa + X client libs + fontconfig/freetype: what libgmsh.so in the pip `gmsh` wheel (a Boundary
#   Lab dependency) links. The list is `ldd libgmsh.so` on the Ubuntu 24.04 gmsh build (GL, GLU, X11/Xrender/
#   Xcursor/Xfixes/Xext/Xft/Xinerama/Xi, fontconfig, freetype); the nvidia `-base` image carries none of them, and
#   the first CI build (2026-10-04, run 37218364877) failed at `import gmsh` with "libGL.so.1: cannot open shared
#   object file" when only libglu1-mesa + a few X libs were installed. Boundary Lab's own image gets libGL
#   transitively (https://github.com/JWSound/boundary-lab/blob/bb9030c4ae0b5906569b3b3932e221a0c97670ac/Dockerfile).
#   The `import gmsh` in the venv step stays as the proof: it fails the build if a library is missing. The apt `gmsh`
#   package is NOT installed: it would be a second gmsh, of another version, beside the pip one.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git openssh-server rsync procps tini \
      python3 python3-venv \
      libgl1 libglu1-mesa libx11-6 libxrender1 libxcursor1 libxfixes3 libxext6 libxft2 libxinerama1 libxi6 \
      libfontconfig1 libfreetype6 libgomp1 \
 && rm -rf /var/lib/apt/lists/* \
 # host keys are generated per pod in start.sh: keys baked into a published image would be shared by every pod
 && rm -f /etc/ssh/ssh_host_* \
 # start.sh hands the container env to ssh sessions through /etc/environment, which pam_env reads for every ssh
 # session (login or `ssh host cmd`; pam_env reads /etc/environment by default, readenv=1). Noble's sshd PAM file
 # has `session required pam_env.so # [1]` under "Read environment variables from /etc/environment".
 # https://git.launchpad.net/ubuntu/+source/openssh/plain/debian/openssh-server.sshd.pam.in?h=ubuntu/noble
 # https://help.ubuntu.com/community/EnvironmentVariables#A.2Fetc.2Fenvironment
 # Fail the build if this sshd's PAM stack does not include it, or PAM is off.
 && grep -Eq '^session\s+required\s+pam_env\.so(\s|$)' /etc/pam.d/sshd \
 && grep -Eq '^UsePAM\s+yes' /etc/ssh/sshd_config

# ---- Julia ---------------------------------------------------------------------------------------------------------
# Official x86_64 tarball (289,794,236 bytes on 2026-10-04). https://julialang.org/downloads/
# /usr/local/bin symlinks rather than PATH edits: /usr/local/bin is on PATH in every shell, ssh or exec.
RUN curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-${JULIA_VERSION}-linux-x86_64.tar.gz \
      | tar xz -C /opt \
 && ln -s /opt/julia-${JULIA_VERSION}/bin/julia /usr/local/bin/julia \
 && julia --version

# ---- Boundary Lab at the pin, plus the BEAT Engine 0.3.0 patch -----------------------------------------------------
# The patch moves Boundary Lab's BEAT Engine pin 0.2.0 -> 0.3.0 (wheel URL + sha256, version check, its test).
# Applied to the working tree so HEAD stays the pin. Its single source is the studio repo's
# tools/boundary-lab/beat-engine-0.3.0.patch; it goes away when upstream moves its own pin.
COPY beat-engine-0.3.0.patch /opt/beat-engine-0.3.0.patch
RUN git clone https://github.com/JWSound/boundary-lab /opt/boundary-lab \
 && git -C /opt/boundary-lab checkout ${BLAB_COMMIT} \
 && git -C /opt/boundary-lab apply /opt/beat-engine-0.3.0.patch

# ---- venv ----------------------------------------------------------------------------------------------------------
# Ubuntu 24.04's python3 is 3.12; Boundary Lab requires >=3.11 (its pyproject.toml). manifold3d is the same pin as
# the studio devcontainer.
RUN python3 -m venv /opt/blab-venv \
 && /opt/blab-venv/bin/pip install --no-cache-dir /opt/boundary-lab manifold3d==3.5.3 \
 && test "$(/opt/blab-venv/bin/python -c 'import beat_engine; print(beat_engine.__version__)')" = "${BEAT_ENGINE_VERSION}" \
 && /opt/blab-venv/bin/python -c 'import gmsh, blab.solvers.engine_distribution' \
 && ln -s /opt/blab-venv/bin/blab /usr/local/bin/blab

# ---- BEAT Engine, CPU backend --------------------------------------------------------------------------------------
# instantiate = Pkg.instantiate() on the engine's bundled Julia project (beat_engine/__main__.py), which also
# precompiles it. `doctor` starts the CPU worker once: a build that cannot start the worker fails here.
RUN /opt/blab-venv/bin/python -m beat_engine --backend cpu instantiate \
 && /opt/blab-venv/bin/python -m beat_engine --backend cpu doctor > /opt/beat-cpu-doctor.json

# ---- BEAT Engine, CUDA backend, precompiled without a GPU ----------------------------------------------------------
# Without a driver CUDA.jl selects no runtime artifact, downloads nothing, and the precompiled image cannot run GPU
# code. Fixing the runtime version with CUDA.set_runtime_version! makes the selection driver-independent: the next
# import downloads that runtime + compiler artifact and precompiles against it; CUDA.precompile_runtime() then
# precompiles GPUCompiler's device runtime library too. The version must be one the pod's driver supports.
#   https://cuda.juliagpu.org/stable/installation/overview/ ("Precompiling CUDA.jl without CUDA")
# Boundary Lab ships exactly this as docker/prepare_cuda.py (Pkg.instantiate; set_runtime_version!(v"12.8"); then
# `using CUDA, CUDSS; CUDA.precompile_runtime()`), so we run upstream's script rather than a copy of it. It writes
# LocalPreferences.toml into the engine's julia_cuda project inside the venv.
#   https://github.com/JWSound/boundary-lab/blob/bb9030c4ae0b5906569b3b3932e221a0c97670ac/docker/prepare_cuda.py
# CUDA 12.8 needs driver >= 570.26 (https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html, table 3),
# which the base image's NVIDIA_REQUIRE_CUDA enforces at container start.
# The second `instantiate` is BEAT's own entry point, re-run so its CUDA bundle is precompiled with the preference set.
# The `find`s fail the build if the CUDA runtime (cuBLAS) or cuDSS libraries did not land in the depot, i.e. if they
# would otherwise be fetched at pod start.
RUN /opt/blab-venv/bin/python /opt/boundary-lab/docker/prepare_cuda.py \
 && /opt/blab-venv/bin/python -m beat_engine --backend cuda instantiate \
 && find ${JULIA_DEPOT_PATH}/artifacts -name 'libcublas.so.12*' | grep -q . \
 && find ${JULIA_DEPOT_PATH}/artifacts -name 'libcudss.so*' | grep -q . \
 && rm -rf ${JULIA_DEPOT_PATH}/logs

# Offline from here on, so Pkg does not reach the network at pod start; `JULIA_PKG_OFFLINE=false julia ...` lifts it
# for one session. Pkg's wording is "tries to do as much as possible without connecting" -- whether a missing LAZY
# artifact then errors (wanted: loud) or still downloads is an open question (README).
#   https://pkgdocs.julialang.org/v1/api/#Pkg.offline
ENV JULIA_PKG_OFFLINE=true

# ---- start ---------------------------------------------------------------------------------------------------------
# Last, so editing start.sh does not invalidate the multi-GB depot layers above.
COPY --chmod=755 start.sh /start.sh
EXPOSE 22
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/start.sh"]
