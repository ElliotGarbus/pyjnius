# On Android, pyjnius obtains the JVM's JNIEnv from the host application rather
# than creating a JVM itself. Historically this was a *link-time* dependency on
# SDL2 (``-lSDL2`` plus a direct reference to ``SDL_AndroidGetJNIEnv``), which
# (a) hard-linked the wheel to one SDL generation and (b) is incompatible with a
# redistributable PEP 738 wheel built with no host app present.
#
# Instead we resolve the getter at *runtime* via ``dlsym(RTLD_DEFAULT, ...)``.
# A conforming host (a Kivy/SDL app, SDL2 or SDL3) has already loaded its SDL
# library into the process' global symbol namespace before ``import jnius``, so
# whichever getter exists is found without any DT_NEEDED on libSDL*.so.

cdef extern from "dlfcn.h" nogil:
    void *dlsym(void *handle, const char *symbol)
    void *RTLD_DEFAULT

ctypedef JNIEnv *(*_sdl_get_jnienv_t)() noexcept nogil


cdef JNIEnv *get_platform_jnienv() except NULL:
    cdef void *sym

    # SDL3 renamed the getter: SDL_AndroidGetJNIEnv (SDL2) -> SDL_GetAndroidJNIEnv
    # (SDL3). Try SDL3 first, then SDL2.
    sym = dlsym(RTLD_DEFAULT, b"SDL_GetAndroidJNIEnv")
    if sym == NULL:
        sym = dlsym(RTLD_DEFAULT, b"SDL_AndroidGetJNIEnv")

    if sym != NULL:
        return (<_sdl_get_jnienv_t>sym)()

    raise RuntimeError(
        "pyjnius (Android) could not obtain a JNIEnv: no SDL JNIEnv getter "
        "(SDL_GetAndroidJNIEnv / SDL_AndroidGetJNIEnv) was found in the "
        "process. The host application must load its SDL library "
        "(libSDL3.so or libSDL2.so) with global symbol visibility before the "
        "first 'import jnius'."
    )
