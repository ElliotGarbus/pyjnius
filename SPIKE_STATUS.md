# pyjnius Android-wheel spike — status & handoff

**Purpose of this file:** a self-contained handoff so work can continue in the
WSL-connected Cursor window (a fresh agent or a human). It records what has been
done, how to reproduce it, and the exact next steps. Companion to
`ANDROID_WHEEL_PROPOSAL.md` (the design brief).

---

## TL;DR

The **universal, SDL-agnostic Android wheel works.** pyjnius now builds to
`android_24_arm64_v8a` and `android_24_x86_64` (CPython 3.14) via cibuildwheel,
**with no host app present**, with **no `DT_NEEDED` on any `libSDL`** and **no
undefined SDL symbol** (verified at the ELF level), and the wheels **pip-install**
via cross-download. **Steps 2, 3 and 4 are done.** The runtime resolver is
three-tier (SDL3 → SDL2 → `JNI_GetCreatedJavaVMs`), and **both** the SDL-independent
path and the SDL-host path are now confirmed on-device:

- **Step 3 (SDL-less):** the cibuildwheel Android testbed on an API-35 x86_64
  emulator ran `autoclass('java.lang.System').getProperty('java.vm.name')` →
  **`Dalvik`**, `JNIEnv` via the tier-3 `dlopen(libnativehelper)` fallback.
- **Step 4 (real SDL2 host):** a **buildozer/p4a Kivy app** (SDL2 bootstrap) built
  against this source and run on an **API-32 x86_64 emulator** resolved the env via
  **tier 2 (`SDL_AndroidGetJNIEnv`)** and round-tripped to `Dalvik` — deterministic
  across relaunches.

**KEY CORRECTION from Step 4:** the original premise that a host-loaded SDL getter
is reachable via `dlsym(RTLD_DEFAULT, …)` is **false on device**. A CPython
extension `dlopen`'d from site-packages does **not** have the host's
`System.loadLibrary`'d SDL in its default lookup scope (empirically NULL on API 32),
so each tier now `dlopen`s the library **by soname** (`libSDL3.so` / `libSDL2.so` /
`libnativehelper.so`) and `dlsym`s the handle — same fix tier 3 already needed.
ELF verification still shows **no** `DT_NEEDED` on any of them (only
`dlopen`/`dlsym@LIBC`). The one remaining criterion
(Python-implements-Java-interface round-trip) is not yet done.

---

## Environment (WSL2)

- Host: **WSL2, Ubuntu 26.04 LTS, x86_64**
- Python **3.14.4**, pip **25.1.1**, uv **0.11.28**
- Java **17** (`/usr/lib/jvm/java-17-openjdk-amd64`)
- Android SDK at **`~/android-sdk`** (`sdkmanager 20.0`); cibuildwheel auto-installed
  **NDK 27.3.13750724**
- **cibuildwheel 4.1.0** (installed as a `uv` tool → `~/.local/bin/cibuildwheel`)
- `/dev/kvm` present, but the user is **not yet in the `kvm` group** (needed for the
  emulator; requires a one-time privileged step — see Next steps)

**Environment file:** `~/.pyjnius-spike-env.sh` sets `ANDROID_HOME`,
`ANDROID_SDK_ROOT`, `JAVA_HOME`, and `PATH`. Source it before any build:

```bash
source ~/.pyjnius-spike-env.sh
```

**Repo:** this working copy is `~/pyjnius-spike`, a local `git clone` of
`/mnt/c/Users/ellio/PycharmProjects/pyjnius`. `origin` therefore points at the
Windows path — repoint it at the GitHub fork before any upstream PR.

- Build outputs: `~/wheelhouse/`

---

## The two source changes (Android-only; no desktop impact)

### 1. `jnius_config/env.py` — drop the hard SDL link

`AndroidJavaLocation.get_libraries()` now returns `['log']` instead of
`['SDL2', 'log']`. A `DT_NEEDED` on a specific `libSDL*.so` would lock the wheel
to one SDL/Kivy generation and fail to `dlopen` against the other. (`jnius/env.py`
is just a shim that re-exports `jnius_config.env`.)

### 2. `jnius/jnius_jvm_android.pxi` — resolve the JNIEnv at runtime (three-tier)

Replaced the direct `extern SDL_AndroidGetJNIEnv()` call with a runtime
`dlsym(RTLD_DEFAULT, ...)` resolver that tries, in order:

1. `SDL_GetAndroidJNIEnv` (SDL3)
2. `SDL_AndroidGetJNIEnv` (SDL2)
3. `JNI_GetCreatedJavaVMs` + `AttachCurrentThread` (SDL-independent) — **Step 2**

The SDL getters return a `JNIEnv*` directly. The `JNI_GetCreatedJavaVMs` fallback
(`_jnienv_from_created_vm()`) `dlsym`s the symbol, retrieves the process' existing
JavaVM, and `AttachCurrentThread`s to get the `JNIEnv`. If all three fail it
raises a clear `RuntimeError` naming the host contract.

> **API-level scope of the three tiers (settled).** Tiers 1–2 (SDL) are the
> primary path and work on **all** supported API levels (≥ 24): a Kivy/SDL host
> `System.loadLibrary`s SDL, SDL's own `JNI_OnLoad` captures the JavaVM, and SDL
> re-exposes it via the getter we `dlsym`. Tier 3 (`JNI_GetCreatedJavaVMs`) is
> **best-effort, effectively API 31+**: that symbol only became a public
> `libnativehelper` export in Android 12 / API 31 (`introduced=S`,
> [android/ndk#1969](https://github.com/android/ndk/issues/1969)); on API 24–30
> it's outside the app linker namespace and the `dlsym` typically returns `NULL`,
> so a non-SDL host there falls through to the `RuntimeError`. This is fine —
> `minSdk` stays 24 because the SDL path covers those levels for the real target.
>
> **`JNI_OnLoad` is *not* an alternative here.** It's the officially-blessed,
> all-API way to receive the JavaVM, but Android only calls it for libs loaded
> via `System.loadLibrary` (ART does `dlopen` + `dlsym("JNI_OnLoad")`). This `.so`
> is a CPython extension loaded by a plain `dlopen()` on `import`, so ART never
> calls a `JNI_OnLoad` defined in it — it would be dead code. The all-API
> SDL-independent option, if ever needed, is an explicit host-provided setter
> (a §5 runtime-contract API), not autodetection.

Removing every direct symbol reference is **required**, not just preferred: the
NDK link uses `-Wl,--no-undefined`, so any leftover undefined symbol (SDL *or*
JNI) would fail the link. The ELF check below confirms none survive.

> These edits are committed and pushed on branch
> **`spike/android-universal-wheel`** (tracks `origin`). Remotes: `origin` →
> `github.com/ElliotGarbus/pyjnius` (the fork), `upstream` → `github.com/kivy/pyjnius`,
> `local` → the Windows clone `/mnt/c/Users/ellio/PycharmProjects/pyjnius`.

---

## Reproduce the build

```bash
source ~/.pyjnius-spike-env.sh
cd ~/pyjnius-spike

# The Android branch of jnius.pyx needs config.pxi + a pre-generated jnius.c
# (Cython is a build-only tool; consumers of the wheel do not need it).
echo "DEF JNIUS_PLATFORM = 'android'" > jnius/config.pxi
uvx --from "Cython~=3.1.2" cython -3 jnius/jnius.pyx -o jnius/jnius.c

# API level, ABIs, and build frontend are now pinned in
# pyproject.toml [tool.cibuildwheel.android] — no manual exports needed.
# --only computes the platform, so no CIBW_PLATFORM either.
cibuildwheel --only cp314-android_x86_64    --output-dir ~/wheelhouse
cibuildwheel --only cp314-android_arm64_v8a --output-dir ~/wheelhouse
```

### ELF verification (proves the universal design)

```bash
READELF=~/android-sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
# unzip a wheel, then:
$READELF -d        jnius/jnius*.so | grep NEEDED       # -> libm liblog libpython3.14 libdl libc  (NO libSDL)
$READELF --dyn-syms jnius/jnius*.so | grep -i sdl      # -> (none)
$READELF --dyn-syms jnius/jnius*.so | grep -iE "JNI_GetCreatedJavaVMs|AttachCurrentThread"  # -> (none: dlsym'd / vtable, not linked)
$READELF --dyn-syms jnius/jnius*.so | grep -i dlsym    # -> dlsym@LIBC (the runtime resolver)
```

### pip cross-install check

```bash
python3 -m pip install --only-binary=:all: --platform android_24_arm64_v8a \
    --python-version 3.14 --target /tmp/x --no-deps \
    ~/wheelhouse/pyjnius-1.7.0-cp314-cp314-android_24_arm64_v8a.whl
```

---

## Acceptance criteria status (see proposal §8)

- [x] Builds `android_24_arm64_v8a` **and** `android_24_x86_64`, no host app present
- [x] `pip install` cross-download installs cleanly
- [x] Imports/runs on an emulator/device — **both paths confirmed.**
      (a) SDL-less: cibuildwheel testbed, API-35 x86_64 emulator, env via tier-3
      `dlopen(libnativehelper)` + `JNI_GetCreatedJavaVMs` → `Dalvik`.
      (b) Real SDL2 host: buildozer/p4a Kivy app (SDL2 bootstrap) on an API-32
      x86_64 emulator, env via **tier 2 `SDL_AndroidGetJNIEnv`** → `Dalvik`,
      deterministic across relaunches. **SDL3** host not yet exercised (Kivy is
      SDL2; would need an SDL3 host build).
- [~] Python-implements-Java-interface round-trip — **delivery convention now
      SETTLED** (Option B: ship the glue as source in a `.java/` dot-directory; see
      "Java-glue delivery" below). The wheel side is defined; demonstrating the
      round-trip on-device is gated on consumer-side glue routing (p4a needs the
      `.java/`-extraction change in the appended draft issue; `ksproject` already
      extracts `.java/`).
- [x] Reproducible from pinned inputs (locked into `pyproject.toml`
      `[tool.cibuildwheel.android]`; NDK pinned via the cibuildwheel version).
      Caveat: toolchain inputs are pinned, but wheels are not yet *bit-for-bit*
      identical (would additionally need `SOURCE_DATE_EPOCH` etc.)

## Reproducibility pins

Locked in `pyproject.toml` `[tool.cibuildwheel.android]` except where noted.
cibuildwheel has **no NDK-version key**: the NDK is a function of the cibuildwheel
version, so pinning cibuildwheel pins the NDK.

| Input | Value | Where pinned |
|---|---|---|
| NDK | 27.3.13750724 | implied by cibuildwheel 4.1.0 (documented in `pyproject.toml` comment) |
| ANDROID_API_LEVEL | 24 | `[tool.cibuildwheel.android].environment` |
| ABIs | arm64_v8a (ship), x86_64 (test) | `[tool.cibuildwheel.android].archs` |
| build frontend | `build` (Android forbids `pip`) | `[tool.cibuildwheel.android].build-frontend` |
| cibuildwheel | 4.1.0 | operational (uv tool); pin in CI when set up |
| Cython | ~=3.1.2 (3.1.8 used) | `[build-system].requires` |
| CPython target | 3.14 (cp314); add 3.15 pre-release via `--enable cpython-prerelease` | build invocation (`--only`) |

> Verified: building with **no** `ANDROID_API_LEVEL`/`CIBW_PLATFORM` exports still
> produces `android_24_*` — the config alone drives it.

---

## Next steps (agreed plan: option 2 then 3)

### Step 2 — SDL-independent `JNI_GetCreatedJavaVMs` fallback — DONE ✅

Implemented in `jnius_jvm_android.pxi` as `_jnienv_from_created_vm()` /
`_resolve_get_created_javavms()`: if neither SDL getter resolves, obtain the
process' JavaVM via `JNI_GetCreatedJavaVMs` and `AttachCurrentThread` to get the
`JNIEnv`. See Step 3 for the empirical correction to *how* the symbol is resolved
(`dlopen` by soname, not `RTLD_DEFAULT`). Confirmed not linked (ELF check).

### Step 3 — on-device smoke test — DONE ✅

Ran via cibuildwheel's Android testbed on a `--managed maxVersion` (API-35)
x86_64 emulator (KVM available). Result:

```
ANDROID_SMOKE_OK vm.name=Dalvik vendor=The Android Project java.version=0
✓ cp314-android_x86_64 finished
```

`autoclass('java.lang.System')` resolved and `getProperty('java.vm.name')`
returned `Dalvik` — a real ART round-trip, with the `JNIEnv` from the tier-3
fallback (the testbed has no SDL). (`java.version` is `0` on Android; that's
normal — `java.vm.*` carries the real info.) Test config lives in
`pyproject.toml` `[tool.cibuildwheel.android].test-command`.

> **KEY EMPIRICAL FINDING (changed the implementation).** The first run *failed*:
> `dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs")` returned NULL **even on API 35**.
> "Public export at API 31+" means you may *link* `-lnativehelper`, not that the
> symbol is reachable via `RTLD_DEFAULT` — `libnativehelper.so` isn't in the
> extension's default lookup scope. Fix: **`dlopen("libnativehelper.so")` by
> soname** (permitted for apps on API 31+) then `dlsym` the handle. `dlopen` is
> runtime-only, so ELF re-verification shows **no new `DT_NEEDED`** (still no
> libSDL/libnativehelper/libart; only `dlopen`/`dlsym@LIBC`). After this change the
> testbed passes.

### Step 4 — real SDL2 host on device — DONE ✅

cibuildwheel's testbed has **no SDL loaded**, so Step 3 only exercised tier 3, not
the SDL getters. Step 4 closes that gap with a real SDL2 host: a minimal
**buildozer/p4a Kivy app** (`~/sdl-host-test/`, SDL2 bootstrap) built against *this*
source (via `P4A_pyjnius_DIR` + a local recipe that drops p4a's link-time getter
patches and keeps `use_cython.patch`) and run on an **API-32 x86_64 emulator**
(`pyjnius_x86_64` AVD). A one-line `__android_log_print` in the resolver reports the
winning tier to logcat:

```
I pyjnius : JNIEnv source: tier 2 SDL2 (SDL_AndroidGetJNIEnv)
I python  : SDL_HOST_SMOKE_OK vm.name=Dalvik vendor=The Android Project java.version=0
```

Deterministic across relaunches. ELF re-check of the p4a-built `jnius.so`: `NEEDED`
= only `libpython3.14.so`, `liblog.so`, `libdl.so`, `libc.so` — **no libSDL/
libnativehelper/libart**, no directly-linked SDL/`JNI_GetCreatedJavaVMs` symbol,
`dlopen`/`dlsym@LIBC` present.

> **KEY CORRECTION (changed the SDL path too).** The first Step-4 run resolved via
> **tier 3**, not the SDL getter, even though libSDL2 was loaded — i.e.
> `dlsym(RTLD_DEFAULT, "SDL_AndroidGetJNIEnv")` returned NULL. This falsifies the
> spike's original premise (a host-loaded SDL symbol is reachable via
> `RTLD_DEFAULT`). Same root cause as tier 3: an extension `dlopen`'d from
> site-packages does not have the host's `System.loadLibrary`'d SDL in its default
> lookup scope. Fix: `_resolve_sdl_getter()` now tries `RTLD_DEFAULT` first, then
> **`dlopen`s the SDL soname** (`libSDL3.so`/`libSDL2.so`) and `dlsym`s the handle
> — still runtime-only, no `DT_NEEDED`. After this change tier 2 fires. On API
> 24–30 (no tier 3) this SDL path is what carries the wheel; the dlopen-by-soname
> approach works on those levels because libSDL* is an app lib in the app linker
> namespace.

Not yet exercised: an **SDL3** host (Kivy is SDL2) and **arm64** on real hardware
(only x86_64 emulator tested).

### Later

- **Java-glue delivery — DECIDED: option B (`.java/` dot-directory, source only).**
  See the dedicated section below.
- ~~Lock the pins into a `[tool.cibuildwheel]` config in `pyproject.toml`.~~ DONE ✅
- Write the findings deliverable and prepare the upstream PR (`origin` already
  points at the fork; `upstream` at `kivy/pyjnius`).

## Java-glue delivery — decision & consumer compatibility

### What the glue is

A single ~40-line class, `org.jnius.NativeInvocationHandler` (in
`jnius/src/org/jnius/`), with a `native invoke0(...)` method bound at runtime via
`RegisterNatives`. It is **only** needed for the *Python-implements-a-Java-interface*
feature (`PythonJavaClass`/`@java_method`), used in `create_proxy_instance`
(`jnius_proxy.pxi`) via `autoclass('org.jnius.NativeInvocationHandler')`. Plain
`autoclass` + method calls need no glue (Step 3 passed with none present). The hard
requirement is runtime: the class must be **compiled + dex'd into the APK** and
findable by the classloader pyjnius uses — a `.whl` carries no `.dex`, so the
source (or a compiled form) must reach the app's dex step. It cannot be eliminated:
a `java.lang.reflect.Proxy` handler can't be built from pure Python.

### Decision: option B — ship source in the `.java/` dot-directory

The wheel emits `.java/org/jnius/NativeInvocationHandler.java`; a generic consumer
scans installed wheels for `.java/` and adds it to the AGP source set, letting
Gradle compile+dex it. Chosen over the alternatives because it is:

- **generic** — no per-package special-casing in the consumer (any wheel can carry
  glue the same way); this is what `pyjnius-builder` emits and `ksproject` consumes;
- **coupling-free** — shipping *source* (not `.class`/`.jar`/`.dex`) lets AGP build
  it against the app's own `compileSdk`/Java level, so no bytecode/dex/toolchain
  version mismatch;
- **self-describing & single-artifact** — pyjnius stays one PyPI wheel; the app
  author declares nothing.

Also: **drop the precompiled `.class`** currently shipped alongside the `.java`
(desktop-targeted bytecode, re-dex'd anyway, a version footgun). Open sub-items:
align the `.java/` convention with kivy-school/p4a (one convention, not three), and
choose the emit mechanism (port `pyjnius-builder`'s PEP 517 backend, or a minimal
`setup.py`/wheel step that relocates `jnius/src/org/...` → `.java/org/...`).

### Consumer compatibility (same wheel for all three)

The binary half (`.so` + Python) works everywhere as-is; only the *glue* half
differs. The `.java/` payload is inert to consumers that don't read it (e.g. p4a
drops it in site-packages, harmless), so **one wheel serves all three** — no fork.

| Consumer | Binary (`.so`) | Glue (`.java/`) | Work needed |
|---|---|---|---|
| **ksproject** | ✅ as-is | ✅ as-is (already extracts `.java/`) | none |
| **kivyforge** | ✅ as-is | needs a `.java/` extractor | **our side** (planned Android backend) |
| **p4a** | ✅ as-is (prebuilt-wheel support, v2026.05.09 / PR #3280) | not consumed from the wheel | **upstream p4a** (see below) |

`autoclass`-only usage works on all three today with no glue.

### Work required for p4a to fully consume the wheel

Context: p4a **already** installs prebuilt Android wheels (`PyProjectRecipe`,
v2026.05.09, PR #3280: `--extra-index-url`, `--use-prebuilt-version-for`,
`--skip-prebuilt`). But `install_prebuilt_wheel`/`install_wheel` extract the wheel
**only** into `get_python_install_dir` (site-packages) — they do **not** route a
wheel's `.java/` into the app's Java source set / dex. So the glue-dependent
feature raises the classic `ClassNotFoundException: org.jnius.NativeInvocationHandler`
unless one of the following is done:

1. **Preferred — generic `.java/` extraction in p4a's wheel-install path.** When a
   wheel contains a top-level `.java/` dir, copy its tree into the bootstrap's Java
   sources before the Gradle/dex step (the same contract ksproject uses). This is
   package-agnostic: it fixes pyjnius *and every future glue-carrying wheel*, and
   converges p4a + ksproject + kivyforge on one convention. (Symmetry note: p4a
   already has prior art for wheel-carried native dirs; `.java/` is the Java analog
   of `.libs/<abi>/`.)
2. **Localized alternative — update the pyjnius recipe.** Keep a slim pyjnius
   `PyProjectRecipe` that consumes the prebuilt `.so` wheel but still injects the
   glue source it already ships (`add_src`-style), avoiding a duplicate-class
   clash with any wheel-provided copy.
3. **Interim/no-p4a-change fallback:** the app author sets
   `android.add_src = .../NativeInvocationHandler.java` (today's manual workaround).

Recommended ask to the maintainer: **option 1** — teach the prebuilt-wheel
installer to extract a wheel's `.java/` (and, while there, confirm `.libs/<abi>/`
handling) into the dex path. Small, generic, and unblocks the whole wheel-only
Android story, not just pyjnius.

## Open risks to settle empirically

- ~~Is `JNI_GetCreatedJavaVMs` reliably `dlsym`-able and does it reach ART across
  API levels?~~ **SETTLED EMPIRICALLY (Step 3).** It's a public `libnativehelper`
  export only on **API 31+** (`introduced=S`, [android/ndk#1969](https://github.com/android/ndk/issues/1969)),
  and `RTLD_DEFAULT` does **not** reach it even at API 35 — must `dlopen`
  `libnativehelper.so` by soname. With that, ART round-trip confirmed on an API-35
  emulator. Best-effort tier 3 (API 31+); SDL path (tiers 1–2) carries API 24–30.
  A 24–30 non-SDL check would just confirm the documented fall-through to RuntimeError.
- ~~Does `dlsym(RTLD_DEFAULT, ...)` find a host-loaded SDL getter on bionic at the
  target API levels?~~ **SETTLED EMPIRICALLY (Step 4): NO.** On a real p4a SDL2
  host (API 32) `dlsym(RTLD_DEFAULT, "SDL_AndroidGetJNIEnv")` returned NULL despite
  libSDL2 being loaded — an extension `dlopen`'d from site-packages doesn't see the
  host's `System.loadLibrary`'d SDL in its default scope. Fix applied: `dlopen` the
  SDL soname (`libSDL3.so`/`libSDL2.so`) and `dlsym` the handle (like tier 3). With
  that, tier 2 resolves and round-trips to `Dalvik`. Still open: **SDL3** host and
  **arm64 on real hardware** (only SDL2 + x86_64 emulator exercised so far).

---

## Appendix — draft p4a issue (file *after* the pyjnius wheel PR is up)

Ready to paste into `kivy/python-for-android`. Fill in `<PYJNIUS_PR>` /
`<WHEEL_INDEX_URL>` once the pyjnius PR and published wheel exist.

**Title:** Prebuilt Android wheels: extract a wheel's `.java/` glue into the bootstrap dex path

**Body:**

### Summary

p4a's prebuilt-wheel install path installs a wheel's Python/`.so` payload but drops
any Java glue the wheel carries, so packages that need a companion Java class (e.g.
pyjnius' `org.jnius.NativeInvocationHandler`) fail at runtime with
`ClassNotFoundException` even though the wheel ships the source. Proposal: when an
installed wheel contains a top-level `.java/` directory, copy its tree into the
bootstrap's Java sources before the Gradle/dex step.

### Background

Prebuilt Android wheel support landed in v2026.05.09 (#3280): `PyProjectRecipe`
installs a compatible prebuilt wheel when available (`--extra-index-url`,
`--use-prebuilt-version-for`, `--skip-prebuilt`). This works for the binary:
`import`/`autoclass` and method calls succeed.

First-party pyjnius Android wheels (see `<PYJNIUS_PR>`) are **universal / SDL-agnostic**
and resolve the `JNIEnv` at runtime (dlsym `SDL_GetAndroidJNIEnv`/`SDL_AndroidGetJNIEnv`,
else `dlopen(libnativehelper.so)` + `JNI_GetCreatedJavaVMs`), so the `.so` needs no
per-app source build. The remaining coupling is the Java glue.

### The problem

`install_prebuilt_wheel()` / `install_wheel()` extract the wheel **only** into
`get_python_install_dir(arch)` (site-packages). A wheel's top-level `.java/` thus
lands at `site-packages/.java/` and is never routed into the bootstrap's Java
sources, so it is not compiled/dex'd into the APK. Result — the long-standing:

```
jnius.jnius.JavaException: JVM exception occurred:
Didn't find class "org.jnius.NativeInvocationHandler" ... ClassNotFoundException
```

This only affects the *Python-implements-a-Java-interface* feature (`PythonJavaClass`,
`@java_method`, and anything built on it such as parts of Plyer); plain `autoclass`
usage is unaffected.

### Proposed fix (generic, package-agnostic)

In the prebuilt-wheel install path, after extracting a wheel, if it contains a
top-level `.java/` directory, copy its tree into the bootstrap's Java source set
(the location already fed to Gradle/`javac`/dex). Notes:

- **Source, not bytecode:** Gradle compiles it against the app's own `compileSdk`/Java
  level — no `.class`/dex/toolchain-version coupling.
- **Preserve package paths** (`.java/org/jnius/...` → `org/jnius/...`).
- **Java analog of `.libs/<abi>/`:** worth confirming/settling `.libs/<abi>/`
  handling on the prebuilt-wheel path in the same change.
- **One convention:** this is the same `.java/` dot-directory contract that
  `pyjnius-builder` emits and `ksproject` consumes, so p4a, ksproject and other
  wheel-native generators converge on a single mechanism — and it fixes *every*
  future glue-carrying wheel, not just pyjnius.

### Alternatives considered

1. **Recipe injects glue:** a slim pyjnius `PyProjectRecipe` consumes the prebuilt
   `.so` wheel but still `add_src`'s its own glue. Works, but pyjnius-specific and
   risks a duplicate-class clash with a wheel-provided copy.
2. **Manual `android.add_src = .../NativeInvocationHandler.java`:** today's
   workaround; keeps failing for users who don't know to do it.

### References

- pyjnius universal Android wheel: `<PYJNIUS_PR>`
- Prebuilt wheel support: #3280 (v2026.05.09)
- `.java/` convention prior art: kivy-school `pyjnius-builder` (emits `.java/`),
  `ksproject` (extracts `.java/`, `.libs/<abi>/`, `.gradle/*.json`)
- Historical glue `ClassNotFoundException`: kivy/pyjnius#137, #223, #645
