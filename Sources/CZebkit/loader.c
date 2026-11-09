/* Finds the engine and opens it: see zebkit_loader.h. */

#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "zebkit_loader.h"

#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#include "loader_internal.h"
#include "release.h"

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

#if defined(__APPLE__) && defined(__aarch64__)
#define ZK_TARGET "aarch64-apple-darwin"
#elif defined(__linux__) && defined(__x86_64__)
#define ZK_TARGET "x86_64-unknown-linux-gnu"
#endif

/* The library inside a package directory. */
#ifdef __APPLE__
#define ZK_LIBRARY "Zebkit.framework/Zebkit"
#else
#define ZK_LIBRARY "libzebkit.so.1"
#endif

static const struct {
    const char *target;
    const char *sha256;
} archives[] = {ZK_RELEASE_ARCHIVES};

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
/* Written once, under the mutex, and never changed after: read without it. */
static void *library;
static char *library_path;
static char *library_directory;

__attribute__((format(printf, 1, 2))) static char *format(const char *pattern, ...) {
    va_list arguments;
    va_start(arguments, pattern);
    char *text = NULL;
    if (vasprintf(&text, pattern, arguments) < 0)
        text = NULL;
    va_end(arguments);
    return text;
}

static void set_error(char **error, char *message) {
    if (error)
        *error = message;
    else
        free(message);
}

static bool is_set(const char *value) {
    return value && *value;
}

const char *zk_release_version(void) {
    return ZK_RELEASE_VERSION;
}

const char *zk_release_target(void) {
#ifdef ZK_TARGET
    return ZK_TARGET;
#else
    return NULL;
#endif
}

const char *zk_release_sha256(const char *target) {
    if (!target)
        return NULL;
    for (size_t index = 0; archives[index].target; ++index) {
        if (!strcmp(archives[index].target, target))
            return archives[index].sha256;
    }
    return NULL;
}

char *zk_engine_cache_directory(void) {
    const char *given = getenv("ZEBKIT_CACHE_DIR");
    if (is_set(given))
        return strdup(given);
    const char *cache = getenv("XDG_CACHE_HOME");
    if (is_set(cache))
        return format("%s/zebkit", cache);
    const char *home = getenv("HOME");
    if (is_set(home))
        return format("%s/.cache/zebkit", home);
    return NULL;
}

/* The directory the executable is in, or NULL. The caller's to free(). */
static char *executable_directory(void) {
    char path[PATH_MAX];
#ifdef __APPLE__
    char given[PATH_MAX];
    uint32_t size = sizeof given;
    if (_NSGetExecutablePath(given, &size) != 0 || !realpath(given, path))
        return NULL;
#else
    ssize_t length = readlink("/proc/self/exe", path, sizeof path - 1);
    if (length <= 0)
        return NULL;
    path[length] = '\0';
#endif
    char *slash = strrchr(path, '/');
    if (!slash)
        return NULL;
    *slash = '\0';
    return strdup(path);
}

static bool has_engine(const char *directory) {
    char *path = format("%s/%s", directory, ZK_LIBRARY);
    bool found = path && access(path, F_OK) == 0;
    free(path);
    return found;
}

/*
 * The package directory to open when the application names none, or NULL
 * with the places that were looked in as @error. The caller's to free().
 */
static char *find_engine(char **error) {
    const char *given = getenv("ZEBKIT_DIR");
    if (is_set(given)) {
        if (has_engine(given))
            return strdup(given);
        *error = format("ZEBKIT_DIR is %s, which has no %s", given, ZK_LIBRARY);
        return NULL;
    }

    char *candidates[5] = {NULL};
    size_t count = 0;
    char *beside = executable_directory();
    if (beside) {
        candidates[count++] = format("%s/zebkit", beside);
        candidates[count++] = format("%s/../zebkit", beside);
        candidates[count++] = strdup(beside);
#ifdef __APPLE__
        candidates[count++] = format("%s/../Frameworks", beside);
#endif
        free(beside);
    }
    char *cache = zk_engine_cache_directory();
    if (cache && zk_release_target())
        candidates[count++] = format("%s/zebkit-%s-%s", cache, ZK_RELEASE_VERSION, zk_release_target());
    free(cache);

    char *found = NULL;
    char *looked = strdup("");
    for (size_t index = 0; index < count; ++index) {
        char *candidate = candidates[index];
        if (!candidate)
            continue;
        if (!found && has_engine(candidate)) {
            found = candidate;
            continue;
        }
        if (!found && looked) {
            char *longer = format("%s\n  %s", looked, candidate);
            free(looked);
            looked = longer;
        }
        free(candidate);
    }
    if (!found) {
        *error = format("the zebkit engine (%s) was not found. Looked in:%s\n"
                        "Download it with `swift run zebkit-engine install`, or set ZEBKIT_DIR to an engine's "
                        "package directory.",
                        ZK_LIBRARY, looked ? looked : "");
    }
    free(looked);
    return found;
}

/* Whether @engine, the library's own version, may be used with these headers. */
static bool versions_agree(const char *engine) {
    if (is_set(getenv("ZEBKIT_ALLOW_VERSION_MISMATCH")))
        return true;
    /* Up to and including the second dot: "0.4." of "0.4.0". */
    const char *headers = ZK_RELEASE_VERSION;
    const char *dot = strchr(headers, '.');
    dot = dot ? strchr(dot + 1, '.') : NULL;
    size_t length = dot ? (size_t)(dot - headers) + 1 : strlen(headers) + 1;
    return !strncmp(engine, headers, length);
}

/* With the mutex held. */
static bool load_locked(const char *directory, char **error) {
    if (library)
        return true;
    char *found = NULL;
    if (is_set(directory)) {
        if (!has_engine(directory)) {
            *error = format("%s has no %s: it is not a zebkit package directory", directory, ZK_LIBRARY);
            return false;
        }
    } else {
        found = find_engine(error);
        if (!found)
            return false;
        directory = found;
    }

    /* Resolved, so that what the engine learns of where it is does not
     * depend on the working directory, which may change. */
    char joined[PATH_MAX], resolved[PATH_MAX];
    snprintf(joined, sizeof joined, "%s/%s", directory, ZK_LIBRARY);
    const char *path = realpath(joined, resolved) ? resolved : joined;
    char directory_resolved[PATH_MAX];
    const char *directory_path = realpath(directory, directory_resolved) ? directory_resolved : directory;

    /* Local: the engine's symbols are reached through dlsym() alone, and
     * the thousands it exports (zebkit_vendor_*: SQLite, zlib, FFmpeg and
     * the rest) stay out of the way of the program's own libraries. */
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *reason = dlerror();
        *error = format("cannot open %s: %s", path, reason ? reason : "unknown error");
        free(found);
        return false;
    }
    const char *(*version)(void) = (const char *(*)(void))dlsym(handle, "zebkit_version");
    const char *engine_version = version ? version() : NULL;
    if (!engine_version || !versions_agree(engine_version)) {
        *error = format("%s is zebkit %s, and this program was built for zebkit %s. Install the matching engine "
                        "(`swift run zebkit-engine install`), or set ZEBKIT_ALLOW_VERSION_MISMATCH=1 to use this "
                        "one at your own risk.",
                        path, engine_version ? engine_version : "of no known version", ZK_RELEASE_VERSION);
        /* Not closed: Chromium's library is not made to be unloaded. */
        free(found);
        return false;
    }
    library_path = strdup(path);
    library_directory = strdup(directory_path);
    __atomic_store_n(&library, handle, __ATOMIC_RELEASE);
    free(found);
    return true;
}

bool zk_engine_load(const char *directory, char **error) {
    char *message = NULL;
    pthread_mutex_lock(&mutex);
    bool loaded = load_locked(directory, &message);
    pthread_mutex_unlock(&mutex);
    set_error(error, message);
    return loaded;
}

bool zk_engine_is_loaded(void) {
    return __atomic_load_n(&library, __ATOMIC_ACQUIRE) != NULL;
}

const char *zk_engine_directory(void) {
    return zk_engine_is_loaded() ? library_directory : NULL;
}

const char *zk_engine_library_path(void) {
    return zk_engine_is_loaded() ? library_path : NULL;
}

void *zk_engine_symbol(const char *name) {
    void *handle = __atomic_load_n(&library, __ATOMIC_ACQUIRE);
    return handle && name ? dlsym(handle, name) : NULL;
}

void *zk_engine_require(const char *name) {
    char *error = NULL;
    if (!zk_engine_load(NULL, &error)) {
        fprintf(stderr, "zebkit: %s() was called, but %s\n", name, error ? error : "the engine could not be opened");
        abort();
    }
    void *address = zk_engine_symbol(name);
    if (!address) {
        fprintf(stderr, "zebkit: the engine at %s has no %s()\n", library_path, name);
        abort();
    }
    return address;
}
