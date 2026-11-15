/*
 * The Mac app's way into the shared Lua (measuring, map reading, profile
 * files). Plain C so Swift can call it and the tests can run it anywhere.
 * Every string returned is malloc'd JSON: free it with npvf_free.
 */
#ifndef NPVF_BRIDGE_H
#define NPVF_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct npvf npvf;

/* Called after each test note; return non-zero to stop measuring. */
typedef int (*npvf_progress)(void *context, int done, int total);

/* Start Lua and load npvf_app.lua (and the modules beside it) from `dir`.
   On failure returns NULL and writes why into `err`. */
npvf *npvf_open(const char *dir, char *err, size_t errlen);
void npvf_close(npvf *v);

/* Call App.<fn> in npvf_app.lua with JSON arguments; returns JSON (an
   { "error": ... } object if it failed). */
char *npvf_call(npvf *v, const char *fn, const char *argsJson);

/* Measure a mono render (`frames` samples at `fs`) of the test part in
   `requestJson` (see npvf_measure in npvf_app.lua). Returns JSON:
   { profile, file, stats, warnings } or { error } ("stopped" if stopped). */
char *npvf_measure(npvf *v, const float *mono, long frames, double fs,
                   const char *requestJson, npvf_progress progress, void *context);

void npvf_free(char *s);

#ifdef __cplusplus
}
#endif

#endif
