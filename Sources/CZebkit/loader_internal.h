#ifndef CZEBKIT_LOADER_INTERNAL_H
#define CZEBKIT_LOADER_INTERNAL_H

/*
 * The address of the engine's function @name, for a trampoline. Opens the
 * engine first if nothing has. Does not return without the address: a
 * program that calls zebkit and has no engine, or an engine without the
 * function, is told why and aborted.
 */
void *zk_engine_require(const char *name);

#endif /* CZEBKIT_LOADER_INTERNAL_H */
