/*
 * Finding and opening the engine.
 *
 * The engine is a package directory: on macOS it holds Zebkit.framework, on
 * Linux libzebkit.so.1 with zebkit-helper and the engine's data beside it.
 * It is opened once per process, by zk_engine_load() or by the first call of
 * a zebkit function, whichever comes first.
 */

#ifndef CZEBKIT_LOADER_H
#define CZEBKIT_LOADER_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Opens the engine in @directory, or, with NULL, in the first of:
 *
 *   1. $ZEBKIT_DIR (if set, nowhere else is looked in);
 *   2. beside the executable: <dir>/zebkit, <dir>/../zebkit, <dir> itself,
 *      and on macOS <dir>/../Frameworks (an application bundle);
 *   3. the download cache, zk_engine_cache_directory().
 *
 * True when the engine is open, also when it already was (then @directory is
 * not looked at). False with the reason in @error, which is the caller's to
 * free() (not zebkit_free(): there is no engine to free it); @error may be
 * NULL. An engine whose version differs from the headers' in its major or
 * minor number is refused, unless $ZEBKIT_ALLOW_VERSION_MISMATCH is set.
 */
bool zk_engine_load(const char *directory, char **error);

bool zk_engine_is_loaded(void);

/* The package directory the engine was opened from; NULL before that. */
const char *zk_engine_directory(void);

/* The library that was opened; NULL before that. */
const char *zk_engine_library_path(void);

/*
 * The address of @name in the engine, for what the headers here do not
 * declare (zebkit_vendor_*); NULL when the engine has no such symbol or is
 * not open. Does not open the engine.
 */
void *zk_engine_symbol(const char *name);

/* The version of zebkit these headers are of, as in "0.4.0". */
const char *zk_release_version(void);

/*
 * The name of the release archive's target for this system, as in
 * "aarch64-apple-darwin"; NULL where no engine is released.
 */
const char *zk_release_target(void);

/*
 * The SHA-256 of zebkit-<version>-<target>.tar.xz as released, in
 * hexadecimal; NULL for a target without a release.
 */
const char *zk_release_sha256(const char *target);

/*
 * Where downloaded engines are kept: $ZEBKIT_CACHE_DIR, else
 * $XDG_CACHE_HOME/zebkit, else ~/.cache/zebkit (the Rust crate's cache: an
 * engine one has downloaded serves the other). The caller's to free(); NULL
 * when none of them is set.
 */
char *zk_engine_cache_directory(void);

#ifdef __cplusplus
}
#endif

#endif /* CZEBKIT_LOADER_H */
