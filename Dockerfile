# syntax=docker/dockerfile:1
# ============================================================================
# vybox-eda — a container for building RTL -> GDSII.
#
# Built FROM SCRATCH on Ubuntu 24.04 — no large base image. Each EDA tool is
# installed from its own pinned upstream (source build or official package) into
# a slim, headless runtime. This keeps the image small, version-controlled, and
# buildable on a standard CI runner (the cost is build time, not a multi-GB pull).
#
# Build targets (docker build --target <t>):
#   rtl2gds-base  EDA tools + PDKs only (no Vyges binaries)
#   rtl2gds       (default) rtl2gds-base + the Vyges CLI and EDA engines
#   full          rtl2gds + board / mechanical CAD (KiCad, FreeCAD, OpenSCAD)
#
# Versions are macros (ARG block below; mirrored in versions.lock). "VALIDATE"
# comments mark build flags / refs / runtime-lib closures to confirm on the
# first build. The previous iic-osic-tools-based approach is kept as Dockerfile.orig.
# ============================================================================

# ── Version pins ────────────────────────────────────────────────────────────
ARG UBUNTU_VERSION=24.04
# Python = Ubuntu 24.04 system python3 (3.12). Do not install another interpreter.
ARG PYTHON_VERSION=3.12
# EDA tools (see tools.yml; versions tracked vs the matrix internally).
ARG YOSYS_REF=v0.65
ARG VERILATOR_REF=v5.048
ARG OPENROAD_REF=08f67ee5ecd14db5a42be8c610bbfd1ccf079299
ARG KLAYOUT_VERSION=0.30.8
ARG MAGIC_REF=8.3.642
ARG NETGEN_REF=1.5.319
ARG NGSPICE_VERSION=46
ARG OPEN_PDKS_REF=7b70722e33c03fcb5dabcf4d479fb0822d9251c9
ARG RUST_VERSION=1.83
# superset (full) only
ARG KICAD_VERSION=8.0
ARG FREECAD_VERSION=1.0
ARG OPENSCAD_VERSION=2021.01
# Common install prefix every source-built tool uses (one COPY into the runtime).
ARG EDA_PREFIX=/opt/eda

# ============================================================================
# build-deps — shared apt layer for the source builds (cached once).
# ============================================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-${UBUNTU_VERSION} AS build-deps
USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang lld cmake ninja-build git curl ca-certificates \
      pkg-config autoconf automake libtool m4 bison flex gawk tcsh \
      python3 python3-dev python3-pip \
      libreadline-dev zlib1g-dev libffi-dev \
      tcl-dev tk-dev \
      libx11-dev libxaw7-dev libcairo2-dev libncurses-dev \
      libboost-system-dev libboost-python-dev libboost-filesystem-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Yosys (synthesis) — bundles ABC via --recursive ─────────────────────────
FROM build-deps AS yosys
ARG YOSYS_REF
ARG EDA_PREFIX
RUN git clone --depth 1 --branch "${YOSYS_REF}" --recursive \
      https://github.com/YosysHQ/yosys.git /tmp/yosys \
 && make -C /tmp/yosys -j"$(nproc)" PREFIX="${EDA_PREFIX}" \
 && make -C /tmp/yosys install PREFIX="${EDA_PREFIX}" \
 && rm -rf /tmp/yosys

# ── Verilator (RTL sim / lint) ──────────────────────────────────────────────
FROM build-deps AS verilator
ARG VERILATOR_REF
ARG EDA_PREFIX
RUN apt-get update && apt-get install -y --no-install-recommends help2man perl libfl-dev \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch "${VERILATOR_REF}" \
      https://github.com/verilator/verilator.git /tmp/verilator \
 && cd /tmp/verilator && autoconf && ./configure --prefix="${EDA_PREFIX}" \
 && make -j"$(nproc)" && make install && rm -rf /tmp/verilator

# ── Magic (layout / DRC / extraction) ───────────────────────────────────────
FROM build-deps AS magic
ARG MAGIC_REF
ARG EDA_PREFIX
RUN apt-get update && apt-get install -y --no-install-recommends mesa-common-dev libglu1-mesa-dev \
 && rm -rf /var/lib/apt/lists/* \
 && git clone https://github.com/RTimothyEdwards/magic.git /tmp/magic \
 && cd /tmp/magic && git checkout "${MAGIC_REF}" \
 && ./configure --prefix="${EDA_PREFIX}" && make -j"$(nproc)" && make install \
 && rm -rf /tmp/magic

# ── Netgen (LVS) ────────────────────────────────────────────────────────────
FROM build-deps AS netgen
ARG NETGEN_REF
ARG EDA_PREFIX
RUN git clone https://github.com/RTimothyEdwards/netgen.git /tmp/netgen \
 && cd /tmp/netgen && git checkout "${NETGEN_REF}" \
 && ./configure --prefix="${EDA_PREFIX}" && make -j"$(nproc)" && make install \
 && rm -rf /tmp/netgen

# ── ngspice (SPICE) ─────────────────────────────────────────────────────────
FROM build-deps AS ngspice
ARG NGSPICE_VERSION
ARG EDA_PREFIX
RUN curl -fsSL "https://downloads.sourceforge.net/project/ngspice/ng-spice-rework/${NGSPICE_VERSION}/ngspice-${NGSPICE_VERSION}.tar.gz" -o /tmp/ngspice.tgz \
 && tar -xzf /tmp/ngspice.tgz -C /tmp \
 && cd "/tmp/ngspice-${NGSPICE_VERSION}" \
 && ./configure --prefix="${EDA_PREFIX}" --disable-debug --with-readline=yes --enable-openmp \
 && make -j"$(nproc)" && make install && rm -rf /tmp/ngspice*

# ── OpenROAD (floorplan/place/CTS/route/signoff) — the long pole. VALIDATE. ──
# Full source build (~30-60 min). DependencyInstaller pulls its own dep set.
FROM build-deps AS openroad
ARG OPENROAD_REF
ARG EDA_PREFIX
RUN git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD.git /tmp/openroad \
 && cd /tmp/openroad && git checkout "${OPENROAD_REF}" && git submodule update --init --recursive \
 && ./etc/DependencyInstaller.sh -base -common \
 && cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="${EDA_PREFIX}" \
 && cmake --build build -j"$(nproc)" --target install \
 && rm -rf /tmp/openroad

# ── Vyges binaries (Rust) — CLI suite + EDA engines (same Ubuntu = glibc match) ─
# Source from the build context (./src/...); skip for rtl2gds-base.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-${UBUNTU_VERSION} AS vyges-bins
USER root
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
# VALIDATE: cargo build --release each crate; cp binaries into /out/bin.

# ============================================================================
# runtime-base — slim, headless Ubuntu with only the runtime shared libs the
# built tools link (no -dev; g++/make kept for Verilator's generated models).
# VALIDATE the lib set with `ldd ${EDA_PREFIX}/bin/*` on the first build.
# ============================================================================
FROM mcr.microsoft.com/devcontainers/base:ubuntu-${UBUNTU_VERSION} AS runtime-base
USER root
ARG PYTHON_VERSION
ARG KLAYOUT_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    EDA_PREFIX=/opt/eda \
    PDK_ROOT=/opt/pdks \
    PDK=sky130A
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git python3 python3-pip perl tcsh g++ make \
      tcl tk libtcl8.6 libtk8.6 \
      libreadline8t64 zlib1g libffi8 libgomp1 \
      libx11-6 libxaw7 libxext6 libxrender1 libsm6 libice6 libcairo2 libncurses6 \
      libgl1 libglu1-mesa libfontconfig1 \
      libboost-system1.83.0 libboost-filesystem1.83.0 \
      libboost-python1.83.0 libboost-program-options1.83.0 \
 && rm -rf /var/lib/apt/lists/*
# Pin the interpreter (cpython-3.12 ABI for any python tool modules).
RUN python3 --version | grep -q "Python ${PYTHON_VERSION}" \
 || { echo "ERROR: expected Python ${PYTHON_VERSION}, got: $(python3 --version)"; exit 1; }
# KLayout from the official Ubuntu-24 .deb (pinned; pulls its Qt runtime deps).
RUN curl -fsSL "https://www.klayout.org/downloads/Ubuntu-24/klayout_${KLAYOUT_VERSION}-1_amd64.deb" -o /tmp/klayout.deb \
 && apt-get update && apt-get install -y --no-install-recommends /tmp/klayout.deb \
 && rm -f /tmp/klayout.deb && rm -rf /var/lib/apt/lists/*

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

# Tools run headless as root (CLIs run fine as root; use --user "$(id -u):$(id -g)"
# to match host ownership on a bind-mount).

# ============================================================================
# rtl2gds-base — gather the built tools + PDKs. The EDA-only image.
# ============================================================================
FROM runtime-base AS rtl2gds-base
ARG OPEN_PDKS_REF
COPY --from=yosys     /opt/eda /opt/eda
COPY --from=verilator /opt/eda /opt/eda
COPY --from=magic     /opt/eda /opt/eda
COPY --from=netgen    /opt/eda /opt/eda
COPY --from=ngspice   /opt/eda /opt/eda
COPY --from=openroad  /opt/eda /opt/eda
ENV PATH=/opt/eda/bin:/root/.vyges/bin:/usr/bin:/bin
# Open PDKs (sky130A + gf180mcu) via ciel, pinned to an open_pdks SHA. VALIDATE.
RUN pip3 install --no-cache-dir --break-system-packages ciel \
 && mkdir -p "${PDK_ROOT}" \
 && ciel enable --pdk-root "${PDK_ROOT}" --pdk-family sky130   "${OPEN_PDKS_REF}" \
 && ciel enable --pdk-root "${PDK_ROOT}" --pdk-family gf180mcu "${OPEN_PDKS_REF}"
WORKDIR /work
COPY scripts/smoke-test.sh /usr/local/bin/vybox-eda-smoke
RUN chmod +x /usr/local/bin/vybox-eda-smoke
CMD ["vybox-eda-smoke"]

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
RUN apt-get update && apt-get install -y --no-install-recommends \
      kicad openscad freecad \
 && rm -rf /var/lib/apt/lists/*
