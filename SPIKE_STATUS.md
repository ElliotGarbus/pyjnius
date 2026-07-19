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
via cross-download. Two remaining criteria (on-device load + Java-interface
round-trip) are not yet done.

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
to one SDL/Kivy generation and fail to `dlopen` against the other.

### 2. `jnius/jnius_jvm_android.pxi` — resolve the JNIEnv at runtime

Replaced the direct `extern SDL_AndroidGetJNIEnv()` call with a
`dlsym(RTLD_DEFAULT, ...)` lookup: try `SDL_GetAndroidJNIEnv` (SDL3), then
`SDL_AndroidGetJNIEnv` (SDL2). Removing the direct symbol reference is **required**,
not just preferred: the NDK link uses `-Wl,--no-undefined`, so a leftover
undefined SDL symbol would fail the link.

> These edits currently live as copies in this clone. Put them on a git branch
> (see Next steps) so they are tracked.

---

## Reproduce the build

```bash
source ~/.pyjnius-spike-env.sh
cd ~/pyjnius-spike

# The Android branch of jnius.pyx needs config.pxi + a pre-generated jnius.c
# (Cython is a build-only tool; consumers of the wheel do not need it).
echo "DEF JNIUS_PLATFORM = 'android'" > jnius/config.pxi
uvx --from "Cython~=3.1.2" cython -3 jnius/jnius.pyx -o jnius/jnius.c

export CIBW_PLATFORM=android
export ANDROID_API_LEVEL=24
cibuildwheel --only cp314-android_x86_64    --output-dir ~/wheelhouse
cibuildwheel --only cp314-android_arm64_v8a --output-dir ~/wheelhouse
```

### ELF verification (proves the universal design)

```bash
READELF=~/android-sdk/ndk/27.3.13750724/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf
# unzip a wheel, then:
$READELF -d        jnius/jnius*.so | grep NEEDED       # -> libm liblog libpython3.14 libdl libc  (NO libSDL)
$READELF --dyn-syms jnius/jnius*.so | grep -i sdl      # -> (none)
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
- [ ] Imports/runs on an emulator/device (blocked — see Next steps)
- [ ] Python-implements-Java-interface round-trip (Java-glue delivery convention undecided)
- [~] Reproducible from pinned inputs (pins recorded below; not yet locked into `pyproject.toml`)

## Reproducibility pins

| Input | Value |
|---|---|
| NDK | 27.3.13750724 |
| ANDROID_API_LEVEL | 24 |
| cibuildwheel | 4.1.0 |
| Cython | ~=3.1.2 (3.1.8 used) |
| CPython target | 3.14 (cp314); add 3.15 pre-release via `--enable cpython-prerelease` |
| ABIs | arm64_v8a (ship), x86_64 (test) |

---

## Next steps (agreed plan: option 2 then 3)

### Step 2 — `dlsym`'d `JNI_GetCreatedJavaVMs` fallback (do first)

Add an SDL-independent fallback in `jnius_jvm_android.pxi`: if neither SDL getter
resolves, `dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs")` and, if found, get the
JavaVM and `AttachCurrentThread` to obtain the `JNIEnv`. **Must be `dlsym`'d, not
linked**, to avoid re-introducing an undefined symbol under `-Wl,--no-undefined`.
Rationale: it lets the wheel be validated in cibuildwheel's *SDL-less* CPython
testbed (which still runs inside Android's ART VM), and makes the wheel work on
non-SDL hosts — the honest "an in-process JVM exists" contract for PyPI.

### Step 3 — on-device smoke test

1. One-time privileged step (user must run; `sudo` needs a password):
   ```bash
   sudo usermod -aG kvm $USER      # then, from Windows: wsl --shutdown, and reopen
   ```
2. Run the wheel test via cibuildwheel's Android testbed on an x86_64 emulator
   (only the build-host arch is testable): verify
   `autoclass('java.lang.System').getProperty('java.version')` returns.

### Known gotcha — test-harness mismatch

cibuildwheel's testbed has **no SDL loaded**, so the `dlsym` SDL path cannot be
exercised there — only the `JNI_GetCreatedJavaVMs` fallback can (hence Step 2
first). Exercising the SDL path requires a real minimal SDL/Kivy Gradle app.

### Later

- **Java-glue delivery for kivyforge:** the glue ships in the wheel as
  `jnius/src/org/jnius/NativeInvocationHandler.java/.class` (via `package_data`),
  **not** in the `.java/` dot-directory convention that AGP generators auto-extract.
  Decide: teach the kivyforge backend to pull from `jnius/src/...`, or adopt the
  `pyjnius-builder` `.java/` convention.
- Lock the pins into a `[tool.cibuildwheel]` config in `pyproject.toml`.
- Write the findings deliverable and prepare the upstream PR (repoint `origin`).

## Open risks to settle empirically

- Is `JNI_GetCreatedJavaVMs` reliably `dlsym`-able and does it reach ART across API
  levels? (Step 2/3 answers this.)
- Does `dlsym(RTLD_DEFAULT, ...)` find a host-loaded SDL getter on bionic at the
  target API levels? (needs a real SDL host to confirm.)
