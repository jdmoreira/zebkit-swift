/*
 * CZebkit: zebkit's C API (Vendor/zebkit/src/engine/include/zebkit), as a
 * Swift module, with the loader that finds the engine when the program runs.
 *
 * The functions the headers declare are defined in this module as
 * trampolines (trampolines.c, generated): each one calls the function of the
 * same name in the engine's library, which is opened with dlopen() on first
 * use. Nothing of the engine is needed to build, and nothing is asked of the
 * linker.
 */

#ifndef CZEBKIT_H
#define CZEBKIT_H

/* Before the declarations it renames for the linker. */
#include "zebkit_symbols.h"

#include <zebkit/zebkit.h>
#include <zebkit/automation.h>
#include <zebkit/canvas.h>
#include <zebkit/hooks.h>
#include <zebkit/media.h>
#include <zebkit/media_tap.h>
#include <zebkit/media_tools.h>
#include <zebkit/offscreen.h>
#include <zebkit/page.h>
#include <zebkit/pdf.h>
#include <zebkit/services.h>
#include <zebkit/text.h>
#include <zebkit/window.h>

#include "zebkit_loader.h"

#endif /* CZEBKIT_H */
