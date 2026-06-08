# Building VyBox‑EDA — and an open call to the OSS EDA community

> Why a *slim* RTL→GDSII container was harder to build than it should be, what we
> learned doing it from scratch, and a concrete, tiered set of things the tool
> projects could do together to make this dramatically smoother for everyone.

This document has three parts:

1. **[How we built this and why it was needed](#1-how-we-built-this-and-why-it-was-needed)**
2. **[Where the friction actually lives](#2-where-the-friction-actually-lives)** — including the
   specific challenges of building outside the OpenLane 2 / LibreLane happy path
3. **[An open call to action](#3-an-open-call-to-action)** — explicit CTAs, from low‑hanging to
   high‑value, addressed to the projects that can move them

It is written in good faith. Every project named here — OpenROAD, Yosys, Magic,
Netgen, KLayout, ngspice, OpenLane 2, LibreLane, IIC‑OSIC‑TOOLS, open_pdks —
represents an enormous amount of excellent, freely given work that made *this*
container possible in the first place. The point below is not that anything is
broken; it is that a handful of coordinated, mostly‑documentation changes would
turn a multi‑day archaeology dig into an afternoon.

---

## 1. How we built this and why it was needed

### The goal

A **slim, headless, reproducible RTL→GDSII container** with:

- **Explicit pins.** Every tool version lives in a single
  [`versions.lock`](../versions.lock); a clean rebuild reproduces the same set, and
  one pin moves per commit.
- **Built from scratch on a clean Ubuntu LTS** (24.04), not layered on a large
  pre‑baked toolbox — so every dependency is *visible* and debuggable.
- **A builder/runtime split.** Each tool is compiled in its own builder stage; the
  published image carries only the runtime shared libraries it actually links.
- **Namespaced install** under `/opt/vyges/...` so it composes cleanly with other
  tooling and never fights the system tree.
- **Only what an RTL→GDSII build needs.** No desktop, no VNC. (And deliberately no
  `iverilog` — Verilator covers our simulation/lint need.)

### Why the existing options didn't quite fit

There are good containers out there, and we stand on them:

- **[IIC‑OSIC‑TOOLS](https://github.com/iic-jku/IIC-OSIC-TOOLS)** is comprehensive and
  battle‑tested. It is also intentionally a *kitchen‑sink, GUI‑first* environment —
  the opposite of slim. Crucially, its `_build/images/<tool>/scripts/install.sh`
  recipes are the single best public reference for *how to actually compile these
  tools from source on a modern Ubuntu*. We learned the hard parts by reading them,
  and we credit them in [`NOTICE`](../NOTICE).
- **OpenLane 2 / LibreLane** solve the *flow* — orchestration, step graphs,
  configuration. They ship the toolchain as a large, all‑in‑one environment
  (LibreLane via Nix). That is the right design for "give me a working flow," and
  the wrong shape when you want a *small, recomposable* image whose every pin you
  control. (More on this in [Part 2](#the-openlane-2--librelane-happy-path).)
- **OpenROAD's `DependencyInstaller`** is meant to bootstrap a dev environment. As a
  *container dependency layer* it turned out to be the single biggest source of
  friction — see below.

None of these is a slim, from‑source, individually‑pinned RTL→GDSII container that a
downstream consumer can rebuild and audit line by line. So we built one. The
interesting part is everything that fought us on the way.

### The build, blow by blow

What follows is the real sequence of failures and fixes from building OpenROAD (the
long pole) on Ubuntu 24.04. Each is a small thing; together they are a multi‑day
research project. They are reproduced here because *every one of them is a CTA in
disguise.*

| # | Symptom | Root cause | Fix |
|---|---------|-----------|-----|
| 1 | Yosys: `fatal error: FlexLexer.h: No such file` | `--no-install-recommends` stripped `libfl-dev`, which *owns* `FlexLexer.h` | Install `libfl-dev` explicitly |
| 2 | OpenROAD cmake: `Could NOT find absl` | OpenROAD does `find_package(absl REQUIRED)` and expects abseil **pre‑installed**; it builds none of its own deps | Provide abseil (we build OR‑Tools from source with `BUILD_DEPS=ON`, which produces it) |
| 3 | `BoostConfig requires Boost 1.87.0 but found 1.89.0` (then 1.83) at `src/utl`, then `src/drt` | `DependencyInstaller` installs a **prebuilt OR‑Tools that bundles a *static* Boost 1.87** *and* separately builds a *shared* Boost — two Boosts, and the bundled cmake configs pin an exact version that exists nowhere as shared libs | Use **system Boost** (`-DUSE_SYSTEM_BOOST=ON`) **and delete OR‑Tools' bundled Boost cmake configs** (`rm -rf /opt/or-tools/lib/cmake/Boost-* …/boost_* …/include/boost …/libboost_*`). OR‑Tools statically links Boost, so it doesn't need them. |
| 4 | OpenROAD cmake: `Could NOT find OpenGL` even with `-DBUILD_GUI=OFF` | `src/gui` was still being *configured*; `DependencyInstaller`'s Qt list pins `qt5-default`, **removed in Ubuntu 24.04**, so its Qt apt step silently no‑ops | Set the GUI off path correctly + install Qt5/OpenGL explicitly when GUI is wanted |
| 5 | OpenROAD cmake: `Could NOT find GTest` **with `-DENABLE_TESTS=OFF`** | OpenSTA's `src/sta/CMakeLists.txt` calls `find_package(GTest)` unconditionally — `ENABLE_TESTS=OFF` does not gate it | Install `libgtest-dev`/`libgmock-dev` even though we build no tests |
| 6 | SWIG‑generated code references `Tcl_Size` (undefined) | SWIG ≥ 4.3 emits `Tcl_Size`; Ubuntu ships Tcl 8.6 which predates that typedef | Build SWIG 4.3 from source (Ubuntu has 4.2) **and** shim `Tcl_Size` into `tcl.h` |
| 7 | Runtime: `openroad: error while loading shared libraries: libboost_serialization.so.1.83.0` | A *slim* runtime image carries only the libs you list; OpenROAD links Boost serialization/thread/iostreams + `libyaml-cpp` + `libortools.so`, none obvious from the build logs | `ldd` the final binary; carry exactly those runtime libs (and put `/opt/or-tools/lib` on `LD_LIBRARY_PATH`) |
| 8 | `ciel: not found` during PDK fetch | A minimal `ENV PATH` override dropped `/usr/local/bin`, where `pip` installs console scripts | Restore `/usr/local/bin` on `PATH` |

The throughline: **OpenROAD builds none of its own dependencies.** It expects a
pre‑populated `/opt/or-tools` (which transitively supplies abseil, re2, protobuf,
SCIP, Clp, Cbc), plus CUDD, LEMON, GTest, SWIG ≥ 4.3, spdlog, and a *consistent*
Boost — and the official `DependencyInstaller` satisfies that contract in a way that
fights a from‑source, system‑Boost container. The fix that finally worked is the one
IIC‑OSIC‑TOOLS arrived at years ago: **don't use `DependencyInstaller`; build
OR‑Tools 9.14 from source, strip its bundled Boost, use system Boost.** That single
insight is buried in a community build script, not in OpenROAD's docs.

> **The strategic point:** others have already done this work. What is missing is not
> capability — it is a *consumable contract*. Most of the eight failures above are
> documentation or packaging gaps, not engineering ones.

---

## 2. Where the friction actually lives

Stepping back from the individual bugs, the friction clusters into five recurring
patterns. None is any one project's fault; they are emergent properties of a dozen
independently‑evolving repos.

### a. Vendored, version‑pinned dependencies that collide

OpenROAD's `DependencyInstaller` bundles a prebuilt OR‑Tools that ships its *own*
static Boost with cmake configs pinning an exact version. The moment your environment
has any other Boost, `find_package(Boost)` demands the bundled version and fails. The
established workaround — delete the vendored Boost artifacts — is undocumented.

### b. Undocumented `find_package` contracts

`find_package(absl REQUIRED)`, `find_package(ortools)`, `find_package(GTest)`,
CUDD/LEMON discovery — OpenROAD assumes each is pre‑installed at a conventional
prefix, but there is no single document that says *"to build OpenROAD from source
without DependencyInstaller, pre‑install exactly these N packages at these prefixes."*
You discover the list one cmake error at a time.

### c. `ENABLE_TESTS=OFF` that doesn't disable test dependencies

`find_package(GTest)` runs even with tests off. A flag that says "off" should turn
the whole subtree off, including its dependency probes.

### d. Distribution drift

`qt5-default` was removed in Ubuntu 24.04; SWIG advanced to 4.3 and started emitting
`Tcl_Size` while distros still ship Tcl 8.6; `--no-install-recommends` quietly removes
*load‑bearing* recommends (`libfl-dev` owns `FlexLexer.h`; `libre2-dev` recommends
`libabsl-dev`). Build recipes pinned to last year's distro silently no‑op or miss
files on this year's.

### e. No single source of truth for "what versions go together"

Which Yosys, OpenROAD, Magic, KLayout, and open_pdks revisions are *co‑tested*? Today
that knowledge is implicit in each flow's lockfile or container tag. There is no
shared, machine‑readable "this set is known‑good together" table that a third party
can consume to build their own image.

### The OpenLane 2 / LibreLane happy path

OpenLane 2 and its successor LibreLane are excellent at the thing they are for: a
reproducible *flow*. LibreLane's move to **Nix** is, for reproducibility, genuinely
the right call — a Nix flake pins the entire transitive graph exactly.

The friction is not correctness; it is **shape and reusability**:

- **All‑or‑nothing.** The environment is designed to be consumed whole. Reusing a
  *single* tool at a *specific* pin, on a *non‑Nix*, slim apt base, means stepping
  off the path — and off the path, the dependency graph that Nix resolved for you is
  opaque.
- **Steep on‑ramp for recomposition.** If your target is a 200 MB apt‑based runtime
  image rather than a Nix store, the Nix derivations don't translate; you are back to
  compiling from source and rediscovering the contracts in Part 1.
- **Flow‑coupled tool knowledge.** The hard‑won "how to build OpenROAD on Ubuntu
  24.04" knowledge lives inside the flow's packaging, not as a standalone,
  distro‑native recipe that anyone can lift.

To be clear: this is a reasonable design choice for a flow. The gap is that there is
no *lightweight, distro‑native, per‑tool* counterpart for people who need to
recompose rather than consume — which is exactly the gap IIC‑OSIC‑TOOLS' install
scripts fill, informally, today.

---

## 3. An open call to action

Here is the constructive part. Below are concrete, mostly‑small things that would
compound across the whole ecosystem. They are tiered by effort‑to‑value so that the
**low‑hanging ones can ship this week** and the high‑value ones can be a roadmap.

We are volunteering to help with several of these — see
[How to engage](#how-to-engage).

### 🟢 Low‑hanging (documentation & metadata — days, not weeks)

1. **Document the from‑source dependency contract.** For each tool, a single page:
   *"To build from source without our bootstrapper, pre‑install exactly these
   packages at these prefixes."* For OpenROAD specifically: state that it expects
   OR‑Tools at `/opt/or-tools`, abseil/CUDD/LEMON/GTest/SWIG≥4.3/spdlog
   pre‑installed, and a single consistent Boost.
2. **Publish a per‑release runtime SBOM / `ldd` manifest.** "These are the shared
   libraries the released binary links." This alone eliminates failure #7 above for
   every slim‑image builder.
3. **Document the OR‑Tools Boost‑artifact gotcha** in OpenROAD's build docs (or stop
   bundling a conflicting static Boost). The fix is one `rm`; the *knowledge* is the
   scarce resource.
4. **Make `ENABLE_TESTS=OFF` gate `find_package(GTest)`** (and any other test‑only
   probes). Small CMake change, removes a whole class of confusion.
5. **Audit `--no-install-recommends` recipes** for load‑bearing recommends
   (`libfl-dev`, `libabsl-dev`, …) and list them explicitly. Recommends are not a
   stable contract.

### 🟡 Medium (shared artifacts & conventions — a focused effort)

6. **A shared, machine‑readable "co‑tested set" matrix.** One source of truth mapping
   `{Yosys, OpenROAD, Magic, Netgen, KLayout, ngspice, open_pdks}` revisions that are
   verified to work together — consumable by anyone building an image. (We maintain a
   private version of exactly this internally and would happily help seed a public
   one; this repo's [`versions.lock`](../versions.lock) + [`tools.yml`](../tools.yml)
   are a starting shape.)
7. **Promote per‑tool, distro‑native build recipes to first‑class artifacts.**
   IIC‑OSIC‑TOOLS' `install.sh` scripts are the de‑facto standard already — bless a
   canonical, tested, *standalone* per‑tool recipe (not coupled to a flow or a Nix
   store) that downstreams can lift verbatim.
8. **Relocatable / prefix‑clean installs.** Ensure each tool installs cleanly under an
   arbitrary `--prefix` with no hard‑coded `/usr/local` assumptions, so namespaced
   layouts (`/opt/...`) "just work."
9. **CI that builds from source on the *current* Ubuntu LTS**, not only inside the
   blessed container — so distro drift (failures #1, #4, #6) is caught upstream the
   week it lands, not by downstream integrators months later.

### 🔴 High‑value (coordinated architecture — a roadmap)

10. **A community‑maintained slim base‑image spec with a builder/runtime split.** A
    minimal, layered RTL→GDSII base that flow tools build *on top of*, instead of each
    re‑bundling the world. Flows keep their orchestration; the toolchain layer becomes
    shared, slim, and pinnable.
11. **A dependency *interface* between flow orchestrators and individual tools.** A
    stable contract — versions, prefixes, runtime libs — so OpenLane/LibreLane and a
    bespoke container can both consume the *same* per‑tool artifact, and a tool can be
    swapped or re‑pinned without forking the flow.
12. **Coordinated release‑train + SBOM publishing across the core tools.** A periodic,
    co‑tested "release set" with published runtime SBOMs, so "what versions go
    together, and what do they link" is answered *by the ecosystem*, once, for
    everyone.

### How to engage

- **Issues / discussion:** this repo's issue tracker is open for feedback on the
  matrix shape, the dependency contracts, and the base‑image spec. We'll cross‑link to
  the relevant upstream trackers as concrete proposals firm up.
- **What we'll contribute:** we're glad to (a) open well‑scoped upstream issues/PRs for
  the 🟢 items we hit directly, (b) help seed a public co‑tested matrix from what we
  already maintain, and (c) keep this container's from‑source recipes public as a
  worked reference (see the [`Dockerfile`](../Dockerfile) — every fix in Part 1 is
  there, commented, with its root cause).

If you maintain one of these tools and any of the above would help — or is already
solved and we missed it — please tell us. The whole point is to **stop everyone from
independently rediscovering the same eight failures.**

---

*Maintained by Vyges. Questions, corrections, and collaboration:*
*<https://vyges.com/contact>.*
