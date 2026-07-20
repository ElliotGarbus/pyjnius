# On Android, pyjnius obtains the JVM's JNIEnv from the host process rather than
# creating a JVM itself. Historically this was a *link-time* dependency on SDL2
# (``-lSDL2`` plus a direct reference to ``SDL_AndroidGetJNIEnv``), which
# (a) hard-linked the wheel to one SDL generation and (b) is incompatible with a
# redistributable PEP 738 wheel built with no host app present.
#
# Instead we resolve the env at *runtime*, in order of preference:
#
#   1. dlsym(RTLD_DEFAULT, "SDL_GetAndroidJNIEnv")  -- SDL3 (primary; all API levels)
#   2. dlsym(RTLD_DEFAULT, "SDL_AndroidGetJNIEnv")  -- SDL2 (primary; all API levels)
#   3. dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs") -- SDL-independent, best-effort
#
# Tiers 1-2 are the primary path and work on every supported API level: a Kivy/SDL
# host loads its SDL library via System.loadLibrary before ``import jnius``, so
# SDL's own JNI_OnLoad has captured the JavaVM, and SDL re-exposes it as the getter
# we dlsym here. This is the only viable mechanism for a *dlopen'd* CPython
# extension (see the JNI_OnLoad note below).
#
# Tier 3 is a *best-effort* fallback for non-SDL hosts (and cibuildwheel's SDL-less
# testbed, which runs a modern maxVersion emulator). IMPORTANT: JNI_GetCreatedJavaVMs
# was only made a public libnativehelper export in Android 12 / API 31
# ("introduced=S"); on API 24-30 it is outside the app's linker namespace and this
# dlsym typically returns NULL. That is acceptable: on those older levels the SDL
# path (tiers 1-2) already supplies the env for the actual target (Kivy apps), and
# a non-SDL host on API < 31 simply falls through to the clear RuntimeError below.
#
# Why NOT JNI_OnLoad(JavaVM*, void*)?  It is the officially-blessed, all-API way to
# receive the JavaVM -- BUT Android only calls it for libraries loaded via Java's
# System.loadLibrary() (ART's LoadNativeLibrary does dlopen + dlsym("JNI_OnLoad")).
# This .so is a CPython extension imported via a plain dlopen(), so ART never calls
# a JNI_OnLoad defined here -- it would be dead code. The host's System.loadLibrary'd
# libs (e.g. SDL) are where JNI_OnLoad legitimately fires; we consume the result of
# theirs via the getters above. A truly SDL-independent, all-API path would require
# the host to hand us the VM explicitly (a §5 runtime-contract setter), not autodetection.
#
# Every symbol here is resolved with dlsym and NONE is linked: the NDK links with
# ``-Wl,--no-undefined``, so a leftover undefined reference (SDL or JNI) would
# fail the link. dlsym keeps the reference dynamic, resolved against whatever the
# host process provides.

cdef extern from "dlfcn.h" nogil:
    void *dlsym(void *handle, const char *symbol)
    void *RTLD_DEFAULT

ctypedef JNIEnv *(*_sdl_get_jnienv_t)() noexcept nogil
ctypedef jint (*_get_created_javavms_t)(JavaVM **, jsize, jsize *) noexcept nogil


cdef JNIEnv *_jnienv_from_sdl():
    # SDL3 renamed the getter (SDL_AndroidGetJNIEnv -> SDL_GetAndroidJNIEnv); try
    # SDL3 first, then SDL2. Returns NULL if neither getter is in the process.
    cdef void *sym = dlsym(RTLD_DEFAULT, b"SDL_GetAndroidJNIEnv")
    if sym == NULL:
        sym = dlsym(RTLD_DEFAULT, b"SDL_AndroidGetJNIEnv")
    if sym == NULL:
        return NULL
    return (<_sdl_get_jnienv_t>sym)()


cdef JNIEnv *_jnienv_from_created_vm():
    # SDL-independent, best-effort path. JNI_GetCreatedJavaVMs is a public
    # libnativehelper export only on API 31+ (Android 12); on API 24-30 this
    # dlsym typically returns NULL (the symbol is outside the app linker
    # namespace) and we return NULL so the caller falls through to a clear
    # error. Where it does resolve, it yields the process' existing JavaVM and
    # we attach the current thread to obtain its JNIEnv. Returns NULL if the
    # symbol is absent, no VM has been created, or the attach fails.
    cdef void *sym = dlsym(RTLD_DEFAULT, b"JNI_GetCreatedJavaVMs")
    if sym == NULL:
        return NULL

    cdef JavaVM *vm = NULL
    cdef jsize n_vms = 0
    if (<_get_created_javavms_t>sym)(&vm, 1, &n_vms) != 0 or n_vms < 1 or vm == NULL:
        return NULL

    cdef void *env = NULL
    if vm[0].AttachCurrentThread(vm, &env, NULL) != 0:
        return NULL
    return <JNIEnv*>env


cdef JNIEnv *get_platform_jnienv() except NULL:
    cdef JNIEnv *env = _jnienv_from_sdl()
    if env == NULL:
        env = _jnienv_from_created_vm()

    if env != NULL:
        return env

    raise RuntimeError(
        "pyjnius (Android) could not obtain a JNIEnv: no SDL JNIEnv getter "
        "(SDL_GetAndroidJNIEnv / SDL_AndroidGetJNIEnv) and no in-process JVM "
        "(JNI_GetCreatedJavaVMs) were found in the process. The host must "
        "provide an in-process JVM before the first 'import jnius' -- e.g. a "
        "Kivy/SDL app loads its SDL library (libSDL3.so or libSDL2.so) with "
        "global symbol visibility, which exposes the SDL getter."
    )
