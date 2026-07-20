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
via cross-download. **Steps 2 and 3 are done.** The runtime resolver is three-tier
(SDL3 → SDL2 → `dlopen(libnativehelper)` + `JNI_GetCreatedJavaVMs`), and the wheel
**imports and round-trips through ART on an emulator** (Step 3): the cibuildwheel
Android testbed on an API-35 x86_64 emulator ran
`autoclass('java.lang.System').getProperty('java.vm.name')` → **`Dalvik`** (vendor
`The Android Project`), with the `JNIEnv` obtained via the SDL-independent tier-3
fallback. ELF verification confirms the resolver added **no** `DT_NEEDED`
(no libSDL, no libnativehelper, no libart — only `dlopen`/`dlsym@LIBC`). The one
remaining criterion (Python-implements-Java-interface round-trip) is not yet done.

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
- [x] Imports/runs on an emulator/device — **SDL-less path only.** cibuildwheel
      testbed, API-35 x86_64 emulator: `autoclass('java.lang.System')` resolved and
      `getProperty('java.vm.name')` returned `Dalvik`, env via the tier-3
      `dlopen(libnativehelper)` + `JNI_GetCreatedJavaVMs` fallback. The SDL-host
      path (SDL2 *and* SDL3) still needs a real minimal SDL/Kivy Gradle app.
- [ ] Python-implements-Java-interface round-trip (Java-glue delivery convention undecided)
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

### Known gotcha — test-harness mismatch (still true)

cibuildwheel's testbed has **no SDL loaded**, so only the tier-3 path is exercised
there, not the SDL getters. Exercising the SDL path (SDL2 *and* SDL3) requires a
real minimal SDL/Kivy Gradle app — the remaining piece for the on-device criterion.

### Later

- **Java-glue delivery for kivyforge:** the glue ships in the wheel as
  `jnius/src/org/jnius/NativeInvocationHandler.java/.class` (via `package_data`),
  **not** in the `.java/` dot-directory convention that AGP generators auto-extract.
  Decide: teach the kivyforge backend to pull from `jnius/src/...`, or adopt the
  `pyjnius-builder` `.java/` convention.
- ~~Lock the pins into a `[tool.cibuildwheel]` config in `pyproject.toml`.~~ DONE ✅
- Write the findings deliverable and prepare the upstream PR (`origin` already
  points at the fork; `upstream` at `kivy/pyjnius`).

## Open risks to settle empirically

- ~~Is `JNI_GetCreatedJavaVMs` reliably `dlsym`-able and does it reach ART across
  API levels?~~ **SETTLED EMPIRICALLY (Step 3).** It's a public `libnativehelper`
  export only on **API 31+** (`introduced=S`, [android/ndk#1969](https://github.com/android/ndk/issues/1969)),
  and `RTLD_DEFAULT` does **not** reach it even at API 35 — must `dlopen`
  `libnativehelper.so` by soname. With that, ART round-trip confirmed on an API-35
  emulator. Best-effort tier 3 (API 31+); SDL path (tiers 1–2) carries API 24–30.
  A 24–30 non-SDL check would just confirm the documented fall-through to RuntimeError.
- Does `dlsym(RTLD_DEFAULT, ...)` find a host-loaded SDL getter on bionic at the
  target API levels? (needs a real SDL host to confirm.)
