# On Android, pyjnius obtains the JVM's JNIEnv from the host process rather than
# creating a JVM itself. Historically this was a *link-time* dependency on SDL2
# (``-lSDL2`` plus a direct reference to ``SDL_AndroidGetJNIEnv``), which
# (a) hard-linked the wheel to one SDL generation and (b) is incompatible with a
# redistributable PEP 738 wheel built with no host app present.
#
# Instead we resolve the env at *runtime*, in order of preference:
#
#   1. dlsym(RTLD_DEFAULT, "SDL_GetAndroidJNIEnv")  -- SDL3
#   2. dlsym(RTLD_DEFAULT, "SDL_AndroidGetJNIEnv")  -- SDL2
#   3. dlsym(RTLD_DEFAULT, "JNI_GetCreatedJavaVMs") -- SDL-independent
#
# A Kivy/SDL host has already loaded its SDL library into the process' global
# symbol namespace before ``import jnius``, so whichever SDL getter exists is
# found without any DT_NEEDED on libSDL*.so. The JNI_GetCreatedJavaVMs fallback
# covers non-SDL hosts (and cibuildwheel's SDL-less testbed): Android's ART is an
# in-process JVM, so the runtime exports JNI_GetCreatedJavaVMs and we attach the
# calling thread to obtain a JNIEnv.
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
    # SDL-independent path: if an in-process JVM already exists (always true under
    # Android's ART), JNI_GetCreatedJavaVMs yields the JavaVM and we attach the
    # current thread to obtain its JNIEnv. Returns NULL if the symbol is absent,
    # no VM has been created, or the attach fails.
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
