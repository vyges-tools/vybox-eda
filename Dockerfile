# syntax=docker/dockerfile:1
# ============================================================================
# vybox-eda — a container for building RTL -> GDSII.
#
# Slim, headless, x86_64 open-EDA toolchain (no desktop/VNC). EDA tool binaries
# come from a pinned iic-osic-tools image (see NOTICE) and are COPYd into a clean
# Ubuntu runtime; the desktop/VNC layers are not shipped.
#
# Build targets (docker build --target <t>):
#   rtl2gds-base  EDA tools + PDKs only (no Vyges binaries)
#   rtl2gds       (default) rtl2gds-base + the Vyges CLI and EDA engines
#   full          rtl2gds + board / mechanical CAD (KiCad, FreeCAD, OpenSCAD)
#
# Versions: see versions.lock and tools.yml. "VALIDATE" comments mark paths and
# library closures to confirm on the first build.
# ============================================================================

# ── Version pins ────────────────────────────────────────────────────────────
ARG UBUNTU_VERSION=24.04
# Python = Ubuntu 24.04's system python3 (3.12). The KLayout/OpenROAD python
# modules COPYd from the base image are cpython-3.12 ABI and the pip tools install
# against it, so do not install a different interpreter.
ARG PYTHON_VERSION=3.12
# The EDA tool set. Pin to a real DATED tag — never "latest".
ARG IIC_OSIC_TOOLS_TAG=2026.05
ARG RUST_VERSION=1.83
# superset (full) only
ARG KICAD_VERSION=8.0
ARG FREECAD_VERSION=1.0
ARG OPENSCAD_VERSION=2021.01

# ============================================================================
# toolsrc — pinned iic-osic-tools image, used as the source of the prebuilt EDA
# tool binaries. Only the /foss tool tree is COPYd into the final image (below);
# the desktop/VNC/X layers are not.
# ============================================================================
FROM hpretl/iic-osic-tools:${IIC_OSIC_TOOLS_TAG} AS toolsrc

# ============================================================================
# runtime-base — slim, headless Ubuntu with only the RUNTIME shared libs the
# /foss tools link against (no -dev, no source toolchain except g++/make, which
# Verilator needs to compile generated models). VALIDATE this set with
# `ldd /foss/tools/*/bin/*` on the pinned image; a missing lib shows up as
# "error while loading shared libraries".
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS runtime-base
ARG PYTHON_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git python3 python3-pip perl tcsh \
      g++ make \
      tcl tk libtcl8.6 libtk8.6 \
      libreadline8t64 zlib1g libffi8 libgomp1 \
      libx11-6 libxaw7 libxext6 libxrender1 libsm6 libice6 libcairo2 libncurses6 \
      libgl1 libglu1-mesa libfontconfig1 \
      libboost-system1.83.0 libboost-filesystem1.83.0 \
      libboost-python1.83.0 libboost-program-options1.83.0 \
 && rm -rf /var/lib/apt/lists/*
# Fail fast if the base ever drifts off the expected interpreter — the COPYd
# KLayout/OpenROAD python modules are built for exactly this cpython ABI.
RUN python3 --version | grep -q "Python ${PYTHON_VERSION}" \
 || { echo "ERROR: expected Python ${PYTHON_VERSION}, got: $(python3 --version)"; exit 1; }

# Image metadata (inherited by all targets built FROM runtime-base).
LABEL maintainer="Shivaram Mysore <shivaram.mysore@gmail.com>" \
      org.opencontainers.image.authors="Shivaram Mysore <shivaram.mysore@gmail.com>" \
      MAINTAINER="Shivaram Mysore <shivaram.mysore@gmail.com>" \
      DESCRIPTION="VyBox EDA tools Container" \
      org.opencontainers.image.url="https://vyges.com" \
      org.opencontainers.image.documentation="https://vyges.com" \
      URL="https://vyges.com" \
      CONTACT="https://vyges.com/contact" \
      BUG_REPORT="https://vyges.com/contact" \
      FEATURE_REQUEST="https://vyges.com/contact"

# Tools run headless as root by default (simplest for CI and bind-mounted
# volumes; the open-EDA CLIs — yosys/openroad/klayout-batch/magic/netgen/ngspice
# — run fine as root). iic-osic-tools' non-root user exists only for its VNC
# desktop, which we don't ship. To match host file ownership on a mount, run with
# `--user "$(id -u):$(id -g)"`.

# ============================================================================
# rtl2gds-base — COPY the EDA tools from toolsrc; add PDKs.
# ============================================================================
FROM runtime-base AS rtl2gds-base
# iic-osic-tools installs its tools under /foss (tools at /foss/tools/<t>,
# PDKs at /foss/pdks). COPY what we ship (see tools.yml); trim unused tools
# (xschem, gaw, xcircuit, …). VALIDATE the exact paths against the pinned image.
COPY --from=toolsrc /foss /foss
ENV PDK_ROOT=/foss/pdks \
    PDK=sky130A
# Put every tool binary on PATH. VALIDATE iic's actual layout (/foss/tools/<t>/bin);
# their setup also exports env in a profile we may need to mirror.
RUN set -eux; \
    for b in /foss/tools/*/bin; do \
      [ -d "$b" ] && find "$b" -maxdepth 1 -type f -perm -u+x \
        -exec ln -sf {} /usr/local/bin/ \; ; \
    done; \
    # iVerilog is not shipped — drop it if present.
    rm -f /usr/local/bin/iverilog /usr/local/bin/vvp 2>/dev/null || true
ENV PATH=/usr/local/bin:/root/.vyges/bin:/usr/bin:/bin
WORKDIR /work
COPY scripts/smoke-test.sh /usr/local/bin/vybox-eda-smoke
RUN chmod +x /usr/local/bin/vybox-eda-smoke
CMD ["vybox-eda-smoke"]

# ============================================================================
# vyges-bins (Rust) — the CLI suite + EDA engines, built on the SAME Ubuntu as
# the runtime so glibc matches. Source comes from the build context (clone the
# repos next to this one first); private repos stay out of the image history.
#   expected build-context layout:
#     ./src/vyges-cli         (vyges, vyges-pdk-store, vyges-catalog)
#     ./src/engines/char|extract|sta-si|em-ir
# For an EDA-only image, build --target rtl2gds-base.
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS vyges-bins
ARG RUST_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential curl ca-certificates pkg-config libssl-dev git \
 && rm -rf /var/lib/apt/lists/* \
 && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal
ENV PATH=/root/.cargo/bin:${PATH}
WORKDIR /src
RUN mkdir -p /out/bin
# COPY ./src ./        # <- uncomment once the build context carries the sources
# VALIDATE: build each crate and stage its binaries into /out/bin, e.g.
#   cargo build --release --manifest-path vyges-cli/Cargo.toml \
#     && cp vyges-cli/target/release/{vyges,vyges-pdk-store,vyges-catalog} /out/bin/
#   for e in char extract sta-si em-ir; do \
#     cargo build --release --manifest-path engines/$e/Cargo.toml \
#       && cp engines/$e/target/release/vyges-$e /out/bin/; done

# ============================================================================
# rtl2gds — the published image: EDA toolchain + Vyges CLI + EDA engines.
# ============================================================================
FROM rtl2gds-base AS rtl2gds
COPY --from=vyges-bins /out/bin /root/.vyges/bin
LABEL org.opencontainers.image.title="vybox-eda" \
      org.opencontainers.image.source="https://github.com/vyges-tools/vybox-eda" \
      org.opencontainers.image.licenses="Apache-2.0"

# ============================================================================
# full — rtl2gds plus board / mechanical CAD (headless).
# ============================================================================
FROM rtl2gds AS full
ARG KICAD_VERSION
ARG OPENSCAD_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      kicad openscad freecad \
 && rm -rf /var/lib/apt/lists/*
# VALIDATE: pin KiCad via the kicad/kicad-${KICAD_VERSION}-releases PPA and
# FreeCAD/OpenSCAD versions if exact pins are required; headless entry points
# are kicad-cli, freecadcmd, openscad.
