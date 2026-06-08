# vybox-eda

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Build & Publish](https://github.com/vyges-tools/vybox-eda/actions/workflows/build-and-publish.yml/badge.svg)](https://github.com/vyges-tools/vybox-eda/actions/workflows/build-and-publish.yml)
[![GHCR](https://img.shields.io/badge/GHCR-vybox--eda-2496ED?logo=github)](https://github.com/orgs/vyges-tools/packages/container/package/vybox-eda)
[![Docker Hub](https://img.shields.io/docker/v/vyges/vybox-eda?logo=docker&label=Docker%20Hub&sort=date)](https://hub.docker.com/r/vyges/vybox-eda)
[![Image size](https://img.shields.io/docker/image-size/vyges/vybox-eda/rtl2gds?logo=docker&label=image%20size)](https://hub.docker.com/r/vyges/vybox-eda)
[![Docker pulls](https://img.shields.io/docker/pulls/vyges/vybox-eda?logo=docker)](https://hub.docker.com/r/vyges/vybox-eda)
[![Quay.io](https://img.shields.io/badge/Quay.io-vybox--eda-EE0000?logo=redhat)](https://quay.io/repository/vyges-tools/vybox-eda)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64-informational)](#)

A container for building **RTL → GDSII**.

`vybox-eda` is a slim, headless, x86_64 image with a pinned open-source EDA
toolchain — no desktop, no VNC, no extras you don't need for a build. Built from
scratch on a pinned Ubuntu so a clean rebuild is reproducible and easy to debug.

## Why VyBox‑EDA

Getting from RTL to a manufacturable **GDSII** normally means assembling a dozen
open‑source tools at mutually‑compatible versions and wiring them together — the
hard, undifferentiated work this image removes. `vybox-eda` is the **build engine**:
a pinned, reproducible, headless toolchain you can drop into CI, a laptop, or a
shuttle‑submission pipeline and get the same result every time. The inputs (your RTL,
or a composed SoC) and the destination (an FPGA, a foundry shuttle, your own PDK)
change; the build does not.

## What you can build with it

**Tape out a design to a foundry shuttle — e.g. [ChipFoundry](https://chipfoundry.io), sky130.**
Run your RTL through synthesis (Yosys) → floorplan · place · route · signoff
(OpenROAD) → DRC (Magic / KLayout) and LVS (Netgen) against the bundled **sky130A**
PDK, and produce a DRC/LVS‑clean **GDSII** ready to submit to a ChipFoundry MPW
shuttle. The whole flow runs headless in this one container — no per‑machine tool
install, the same result on a laptop or in CI.

**Compose a SoC from reusable IPs and harden it to GDSII.**
This is the [Vyges](https://vyges.com) vision: pick verified, reusable IP blocks from
**[VyCatalog](https://vyges.com/products/vycatalog)** — a RISC‑V core, UART, SPI,
SRAM, an accelerator — string them into an SoC, then run the integrated design through
the *same* RTL→GDSII flow in this container to get a tapeout‑ready layout. Reusable
open silicon IP in, manufacturable GDSII out, on an open and fully‑pinned toolchain.

In both cases `vybox-eda` is the consistent, auditable engine in the middle — see
[the docs](docs/building-and-an-open-call.md) for how it's built and why that matters.

## What's in it

The `rtl2gds` image bundles, at versions pinned in [`versions.lock`](versions.lock):

| Tool | Role |
| --- | --- |
| Yosys | RTL synthesis |
| Verilator | RTL simulation / lint |
| OpenROAD | floorplan · place · CTS · route · signoff |
| KLayout | layout · DRC · GDS |
| Magic | layout · DRC · extraction |
| Netgen | LVS |
| ngspice | SPICE |
| open PDKs | sky130A, gf180mcu |
| Vyges CLI suite | `vyges`, `vyges-pdk-store`, `vyges-catalog` |
| Vyges EDA engines | `vyges-char`, `vyges-sta-si`, `vyges-extract`, `vyges-em-ir` |

## Use

The image is published to three registries (all free for public OSS) — pull from
whichever you prefer:

```sh
docker pull ghcr.io/vyges-tools/vybox-eda:rtl2gds     # GitHub Container Registry
docker pull quay.io/vyges-tools/vybox-eda:rtl2gds     # Quay.io
docker pull vyges/vybox-eda:rtl2gds                   # Docker Hub

docker run --rm ghcr.io/vyges-tools/vybox-eda:rtl2gds            # prints tool versions
docker run --rm -v "$PWD:/work" ghcr.io/vyges-tools/vybox-eda:rtl2gds yosys -V
```

(`podman` works identically — substitute `podman` for `docker`.)

## Running tools

Tools run **headless as root** by default — bind-mount your working directory to
`/work` and invoke the tool. Examples (set `IMG=ghcr.io/vyges-tools/vybox-eda:rtl2gds`):

```sh
# Batch / scripted — no display needed
docker run --rm -v "$PWD:/work" $IMG yosys -p 'read_verilog top.v; synth; stat'
docker run --rm -v "$PWD:/work" $IMG openroad -version
docker run --rm -v "$PWD:/work" $IMG magic   -dnull -noconsole -T sky130A drc.tcl
docker run --rm -v "$PWD:/work" $IMG netgen  -batch lvs ...

# KLayout — headless batch (DRC / scripting / layer ops)
docker run --rm -v "$PWD:/work" $IMG klayout -b -r drc.lydrc        # run a DRC script
docker run --rm -v "$PWD:/work" $IMG klayout -zz -r script.py       # no GUI, run script

# Match host file ownership on the mount (instead of root-owned outputs)
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/work" $IMG yosys -V
```

### GUI tools (KLayout / Magic / xterm) over X11

The image is headless (no desktop), but the GUI tools work if you forward your X
display. On **Linux**:

```sh
xhost +local:docker            # allow the container to use your X server
docker run --rm -e DISPLAY -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$PWD:/work" $IMG klayout layout.gds        # opens the KLayout GUI
```

On **macOS/Windows**, run an X server (XQuartz / VcXsrv), allow network clients, and
pass `-e DISPLAY=host.docker.internal:0`.

## Build

```sh
scripts/build.sh rtl2gds-base      # EDA toolchain + PDKs only
scripts/build.sh rtl2gds           # + the Vyges binaries (default)
docker run --rm ghcr.io/vyges-tools/vybox-eda:rtl2gds   # smoke test
```

Versions are macros: edit [`versions.lock`](versions.lock) (and the matching
`ARG` block at the top of the [`Dockerfile`](Dockerfile)) and rebuild — the build
logic never changes. The image builds on `linux/amd64`.

## Documentation

- **[Building VyBox‑EDA — and an open call to the OSS EDA community](docs/building-and-an-open-call.md)**
  — why a *slim* RTL→GDSII container was harder to build than it should be, the
  blow‑by‑blow of the OpenROAD dependency archaeology (with root causes), the
  recurring friction in building outside the OpenLane 2 / LibreLane happy path, and a
  tiered set of concrete CTAs for the tool projects to make this smoother for
  everyone. Every fix it describes is in the [`Dockerfile`](Dockerfile), commented.

## License

Apache-2.0 for this repository's build scripts and configuration. The bundled
tools each carry their own upstream licenses — see [`NOTICE`](NOTICE).
