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
ARG EDA_PREFIX=/opt/vyges/eda

# ============================================================================
# build-deps — shared apt layer for the source builds (cached once).
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS build-deps
USER root
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang lld cmake ninja-build git curl ca-certificates \
      pkg-config autoconf automake libtool m4 bison flex libfl-dev gawk tcsh \
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
# Magic's Makefile has incomplete inter-module dependencies, so `make -j` is racy
# (e.g. cmwind can compile before database/ headers land — fails on some core
# counts, passes on others). Fall back to a serial `make` to finish any object the
# parallel pass missed; it's deterministic and magic is small.
RUN apt-get update && apt-get install -y --no-install-recommends mesa-common-dev libglu1-mesa-dev \
 && rm -rf /var/lib/apt/lists/* \
 && git clone https://github.com/RTimothyEdwards/magic.git /tmp/magic \
 && cd /tmp/magic && git checkout "${MAGIC_REF}" \
 && ./configure --prefix="${EDA_PREFIX}" \
 && { make -j"$(nproc)" || make; } && make install \
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

# ── OpenROAD — built the iic-osic-tools way (the long pole, ~45-90 min). ──────
# OpenROAD does NOT build its own dependencies: src/CMakeLists.txt does
# find_package(absl REQUIRED) and find_package(ortools) against a *prebuilt*
# /opt/or-tools, plus find_package on CUDD and LEMON. We must supply all of them.
# We do NOT use OpenROAD's DependencyInstaller (it pins a prebuilt OR-Tools that
# bundles static Boost 1.87 while separately building shared Boost 1.89 — they
# conflict). Instead, exactly like iic: system Boost (apt) + OR-Tools 9.14 built
# from source to /opt/or-tools, then DELETE OR-Tools' bundled Boost cmake configs
# so OpenROAD's find_package(Boost) resolves to the one consistent system Boost.
FROM build-deps AS openroad
ARG OPENROAD_REF
ARG EDA_PREFIX
ARG ORTOOLS_VERSION=9.14
ARG CUDD_VERSION=3.0.0
ARG LEMON_VERSION=1.3.1
# System deps (iic base-dev's OpenROAD-relevant apt set): full system Boost +
# the libs OpenROAD/OR-Tools need. NOTE: drop --no-install-recommends here so
# libre2-dev pulls libabsl-dev (the same recommends trap that bit libfl-dev);
# abseil also comes from OR-Tools BUILD_DEPS below, this is belt-and-suspenders.
RUN apt-get update && apt-get install -y \
      libboost-all-dev libeigen3-dev libre2-dev libabsl-dev libfmt-dev libyaml-cpp-dev \
      libomp-dev libtbb-dev libgmp-dev libspdlog-dev \
      libgl1-mesa-dev libglu1-mesa-dev \
      libz-dev libzstd-dev libbz2-dev liblzma-dev libssl-dev \
      qtbase5-dev qtbase5-dev-tools libqt5charts5-dev \
 && rm -rf /var/lib/apt/lists/*
# OR-Tools 9.14 from source → /opt/or-tools (per iic 31_install_or-tools.sh).
# BUILD_DEPS=ON builds abseil/re2/protobuf/SCIP/Clp/Cbc and installs them here,
# satisfying OpenROAD's find_package(absl) and find_package(ortools).
# THEN remove OR-Tools' bundled (static, 1.87) Boost cmake configs + headers +
# libs: OR-Tools statically links Boost so it doesn't need them, and leaving them
# makes OpenROAD's find_package(Boost) demand exactly 1.87 (which conflicts with
# the system 1.83/1.89). This single rm is the fix for the src/utl/src/drt
# "Boost-1.87.0 ... boost_iostreams 1.87.0" configure failure.
RUN cd /tmp \
 && wget -q "https://github.com/google/or-tools/archive/refs/tags/v${ORTOOLS_VERSION}.tar.gz" \
 && tar -xf "v${ORTOOLS_VERSION}.tar.gz" && cd "or-tools-${ORTOOLS_VERSION}" \
 && cmake -B build . -DCMAKE_INSTALL_PREFIX=/opt/or-tools -DBUILD_DEPS:BOOL=ON \
      -DBUILD_EXAMPLES:BOOL=OFF -DBUILD_SAMPLES:BOOL=OFF -DBUILD_TESTING:BOOL=OFF \
      -DCMAKE_CXX_FLAGS="-w" -DCMAKE_C_FLAGS="-w" \
 && cmake --build build --config Release -j"$(nproc)" --target install \
 && rm -rf /opt/or-tools/lib/cmake/Boost-* /opt/or-tools/lib/cmake/boost_* \
           /opt/or-tools/include/boost /opt/or-tools/lib/libboost_* \
 && rm -rf /tmp/*
# CUDD 3.0.0 → /usr/local (per iic 32_install_cudd.sh).
RUN cd /tmp && git clone --depth=1 -b "${CUDD_VERSION}" https://github.com/The-OpenROAD-Project/cudd.git \
 && cd cudd && autoreconf && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" install && rm -rf /tmp/*
# LEMON 1.3.1 → /usr/local (per iic 35_install_lemon.sh).
RUN cd /tmp && git clone --depth=1 -b "${LEMON_VERSION}" https://github.com/The-OpenROAD-Project/lemon-graph.git \
 && cd lemon-graph \
 && cmake -D CMAKE_INSTALL_PREFIX=/usr/local -D LEMON_ENABLE_GLPK=NO -D LEMON_ENABLE_COIN=NO \
      -D LEMON_ENABLE_ILOG=NO -D LEMON_ENABLE_SOPLEX=NO -B build . \
 && cmake --build build -j"$(nproc)" --target install && rm -rf /tmp/*
# SWIG >= 4.3 (Ubuntu 24.04 ships 4.2) + spdlog 1.15.1 from source (per iic).
RUN git clone --depth=1 -b v4.3.0 https://github.com/swig/swig.git /tmp/swig \
 && cd /tmp/swig && ./autogen.sh && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" && make install && rm -rf /tmp/swig
RUN git clone --depth=1 -b v1.15.1 https://github.com/gabime/spdlog.git /tmp/spdlog \
 && cd /tmp/spdlog \
 && cmake -DCMAKE_INSTALL_PREFIX=/usr/local -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DSPDLOG_BUILD_EXAMPLE=OFF -B build . \
 && cmake --build build -j"$(nproc)" --target install && rm -rf /tmp/spdlog
# GoogleTest/GMock — OpenSTA's src/sta/CMakeLists.txt does find_package(GTest)
# unconditionally (even with ENABLE_TESTS=OFF). Ubuntu 24.04's packages ship the
# cmake config. Separate layer so the OR-Tools layer above stays cached.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtest-dev libgmock-dev \
 && rm -rf /var/lib/apt/lists/*
# Clone OpenROAD (cached across the cmake/build tweaks below).
RUN git clone --filter=blob:none https://github.com/The-OpenROAD-Project/OpenROAD.git /tmp/openroad \
 && cd /tmp/openroad && git checkout "${OPENROAD_REF}" && git submodule update --init --recursive
# Patch tcl.h (SWIG 4.3 emits Tcl_Size; Ubuntu has Tcl 8.6) + configure + build.
# CMAKE_PREFIX_PATH=/opt/or-tools points find_package at the OR-Tools/absl we built.
# USE_SYSTEM_BOOST=ON; BUILD_GUI=OFF (headless).
RUN grep -q Tcl_Size /usr/include/tcl/tcl.h \
      || printf '\n#ifndef Tcl_Size\ntypedef int Tcl_Size;\n#endif\n' >> /usr/include/tcl/tcl.h \
 && cd /tmp/openroad && mkdir -p build && cd build \
 && cmake .. -DCMAKE_INSTALL_PREFIX="${EDA_PREFIX}" -DSWIG_EXECUTABLE=/usr/local/bin/swig \
      -DCMAKE_PREFIX_PATH=/opt/or-tools -DUSE_SYSTEM_BOOST=ON \
      -DBUILD_GUI=OFF -DENABLE_TESTS=OFF \
 && make -j"$(nproc)" && make install \
 && rm -rf /tmp/openroad

# ── Vyges binaries (Rust) — CLI suite + EDA engines (same Ubuntu = glibc match) ─
# Source from the build context (./src/...); skip for rtl2gds-base.
FROM ubuntu:${UBUNTU_VERSION} AS vyges-bins
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
FROM ubuntu:${UBUNTU_VERSION} AS runtime-base
USER root
ARG PYTHON_VERSION
ARG KLAYOUT_VERSION
ENV DEBIAN_FRONTEND=noninteractive \
    EDA_PREFIX=/opt/vyges/eda \
    PDK_ROOT=/opt/vyges/pdks \
    PDK=sky130A
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git python3 python3-pip perl tcsh g++ make \
      tcl tk libtcl8.6 libtk8.6 \
      libreadline8t64 zlib1g libffi8 libgomp1 \
      libx11-6 libxaw7 libxext6 libxrender1 libsm6 libice6 libcairo2 libncurses6 \
      libgl1 libglu1-mesa libfontconfig1 \
      libboost-system1.83.0 libboost-filesystem1.83.0 \
      libboost-python1.83.0 libboost-program-options1.83.0 \
      libboost-serialization1.83.0 libboost-thread1.83.0 libboost-iostreams1.83.0 \
      libyaml-cpp0.8 \
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
COPY --from=yosys     /opt/vyges/eda /opt/vyges/eda
COPY --from=verilator /opt/vyges/eda /opt/vyges/eda
COPY --from=magic     /opt/vyges/eda /opt/vyges/eda
COPY --from=netgen    /opt/vyges/eda /opt/vyges/eda
COPY --from=ngspice   /opt/vyges/eda /opt/vyges/eda
COPY --from=openroad  /opt/vyges/eda /opt/vyges/eda
# OpenROAD dynamically links OR-Tools (libortools.so + abseil/protobuf/scip);
# carry just the shared libs and put them on the loader path.
COPY --from=openroad  /opt/or-tools/lib /opt/or-tools/lib
ENV PATH=/opt/vyges/eda/bin:/opt/vyges/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LD_LIBRARY_PATH=/opt/or-tools/lib:/usr/local/lib
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
COPY --from=vyges-bins /out/bin /opt/vyges/bin
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
