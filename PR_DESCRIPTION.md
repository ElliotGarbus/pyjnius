# Android: SDL-agnostic, redistributable PEP 738 wheel

## Summary

Today pyjnius on Android must be **compiled from source per app** and is
**hard-linked against a specific SDL** (`-lSDL2`, with a direct reference to
`SDL_AndroidGetJNIEnv`) to obtain its `JNIEnv`. That prevents shipping a single
prebuilt Android wheel and locks pyjnius to one SDL generation.

This PR makes pyjnius buildable as **one redistributable
[PEP 738](https://peps.python.org/pep-0738/) Android wheel** (`android_*` tags)
that works regardless of the host, by resolving the `JNIEnv` **at runtime** with
**no link-time dependency on SDL**. It also wires up a `cibuildwheel` build/test
matrix and (on release) PyPI publishing.

Desktop behavior is unchanged.

## What changed

- **`jnius/jnius_jvm_android.pxi`** — replace the single linked
  `SDL_AndroidGetJNIEnv()` call with a runtime resolver, tried in order:
  1. `SDL_GetAndroidJNIEnv` from `libSDL3.so` (SDL3)
  2. `SDL_AndroidGetJNIEnv` from `libSDL2.so` (SDL2)
  3. `JNI_GetCreatedJavaVMs` from `libnativehelper.so` (SDL-independent, **API 31+**) + `AttachCurrentThread`

  Each tier tries `dlsym(RTLD_DEFAULT, …)` first, then `dlopen`s the library by
  soname and `dlsym`s that handle. Nothing is linked, so the `.so` has **no
  `DT_NEEDED` on any `libSDL`/`libnativehelper`**. If none resolves, the first
  `import jnius` raises a clear `RuntimeError` explaining the host contract.
- **`jnius_config/env.py`** — `AndroidJavaLocation.get_libraries()` drops `'SDL2'`
  → returns `['log']` (no SDL at link time).
- **`setup.py`** — on Android only: skip the `javac`/JDK requirement and exclude
  `src/org/jnius/*` from `package_data`, so the wheel is **Java-free**. (Desktop
  still compiles and bundles `NativeInvocationHandler.class` as before.)
- **`pyproject.toml`** — `[tool.cibuildwheel.android]`: pinned build frontend,
  ABIs (`arm64_v8a`, `x86_64`), API level (24), `LDFLAGS=-Wl,-z,max-page-size=16384`
  (16 KB page alignment for Android 15/16), and an on-device smoke test.
- **`.github/workflows/android-wheels.yml`** — `cibuildwheel` build+test matrix
  with a release-triggered PyPI trusted-publishing job.
- **`docs/source/android-wheel.rst`** — the runtime + Java-glue contract, build
  steps, and verification commands.

## Design notes

- **Why not `JNI_OnLoad`?** It is the all-API, officially-blessed way to receive
  the `JavaVM`, but Android only calls it for libraries loaded via
  `System.loadLibrary()`. This `.so` is a CPython extension imported via a plain
  `dlopen()`, so ART never calls a `JNI_OnLoad` defined here — it would be dead
  code. We instead consume the `JavaVM` that the host's own
  `System.loadLibrary`'d libs (e.g. SDL) captured in *their* `JNI_OnLoad`.
- **Why `dlopen(soname)` and not just `RTLD_DEFAULT`?** Empirically, a CPython
  extension `dlopen`'d from site-packages does **not** have the host's
  `System.loadLibrary`'d SDL (nor `libnativehelper`) in its default lookup scope:
  `dlsym(RTLD_DEFAULT, "SDL_AndroidGetJNIEnv")` returns `NULL` on a real SDL2 host
  (API 32), and `dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs")` returns `NULL` even
  at API 35. `dlopen`ing the (already-resident) library by soname and `dlsym`ing
  that handle resolves both while keeping the reference runtime-only.
- **`JNI_GetCreatedJavaVMs` is best-effort (API 31+).** It became a public
  `libnativehelper` export only in Android 12 (`introduced=S`). On API 24–30 a
  non-SDL host falls through to the `RuntimeError`; that is acceptable because the
  SDL path (tiers 1–2) already covers the real target on all API levels.
- **Java glue is the packager's job.** A `.whl` carries no `.dex`, and a class in
  `site-packages` is not on ART's classpath, so the wheel cannot deliver
  `org.jnius.NativeInvocationHandler` (needed only for `PythonJavaClass` proxies).
  The host build system compiles + dexes it from the canonical source that still
  lives in the repo (`jnius/src/org/jnius/NativeInvocationHandler.java`). The
  native `invoke0` contract and that source are a **matched pair** that must move
  together — documented in `android-wheel.rst`.

## Relationship to prior work

This complements, rather than duplicates, earlier Android-JNIEnv efforts:

- **#732** (`add support to android jvm on termux`, open) and its root issue
  **#247** extend `jnius/jnius_jvm_dlopen.pxi` — the *create/attach-a-VM* path —
  so a **non-SDL** host (termux) can supply a `JNIEnv`. This PR is scoped to
  `jnius/jnius_jvm_android.pxi` — the **SDL-host** path used by
  python-for-android / Kivy — making it SDL-generation-agnostic and adding an
  SDL-independent fallback. Different entry points, same overall goal of
  decoupling the Android `JNIEnv` from a hard SDL link.
- **#541** (`Refactor of env.py`, closed) left Android as an explicit TODO; the
  one-line `get_libraries()` change here is the Android-specific piece for the
  wheel use case.
- The long-dormant `android_jnienv_option` and `dlopen` branches (2014–2015,
  pre-PR-workflow direct pushes) were early sketches of the same "make the Android
  JNIEnv injectable / dlopen-based" idea; this PR carries that intent forward with
  runtime resolution and empirical on-device validation.

Happy to adjust the mechanism if the maintainers would prefer this folded into
`jnius_jvm_dlopen.pxi` alongside #732 instead of the SDL-host `.pxi`.

## Validation

- **cibuildwheel testbed (x86_64 emulator, no SDL):** `autoclass('java.lang.System')`
  round-trips via the **tier-3** `dlopen(libnativehelper)` fallback → `vm.name=Dalvik`.
- **Real SDL2 host (buildozer/p4a Kivy app, API-32 x86_64 emulator):** resolves
  via **tier 2** (`SDL_AndroidGetJNIEnv`); `PythonJavaClass` proxies (`Comparator`,
  `Runnable`) fire `invoke0` on-device; the upstream `ANDROID_ARGUMENT`
  thread-detach hook fires; `jnius_config.vm_running` stays `False` (attaches to
  the host VM, never calls `JNI_CreateJavaVM`).
- **Real arm64 hardware (Pixel 8a, Android 16 / API 36):** all of the above pass;
  ELF is clean (no `libSDL`/`libnativehelper` `DT_NEEDED`, `dlopen`/`dlsym` only,
  `0x4000` LOAD alignment).
- **kivyforge production pipeline (Pixel 8a, API 36):**
  - SDL2 (`pyjnius-deviceinfo`): contract smoke test
    (`EXT_OK` / `PROXY_OK` / `KIVY_CONTRACT_OK` / `SELFTEST_ALL_OK`) and
    `autoclass` device-info reads (`DEVICEINFO_OK`).
  - SDL3 (`hello-sdl3`, Kivy 3.0.0.dev0): same contract markers; instrumented
    build confirmed **tier 1** (`SDL_GetAndroidJNIEnv` from `libSDL3.so`) —
    not a silent tier-3 fallback.
- **Desktop (Linux, Java 17):** `build_ext` + `import jnius` + `autoclass` + a
  `Comparator` proxy round-trip all pass — the `setup.py` guards are no-ops on the
  desktop path.

**All three resolver tiers are empirically confirmed on real arm64 hardware.**

## Maintainer action required

The `publish` job uses [PyPI trusted publishing](https://docs.pypi.org/trusted-publishers/)
(OIDC), which needs a one-time trusted-publisher configured for this repo +
the `pypi` environment. Until then the build/test matrix runs but publishing is
skipped (it only triggers on a GitHub release).

## Backwards compatibility

- Desktop: unchanged (still self-hosts a JVM, still bundles the `.class`).
- Existing python-for-android SDL2 apps: unchanged behavior — the SDL2 getter is
  still used (now via runtime resolution instead of a link-time symbol).
