/*
 * Drives the Mac app's bridge from the command line, for tests/bridge_test.js:
 *
 *   bridge_test <lua-folder> call <fn> <args.json>
 *   bridge_test <lua-folder> measure <render.wav> <request.json> [stop-after-note]
 *
 * Prints the JSON the bridge returns. Reads 32-bit float WAVs (what the tests write).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "npvf_bridge.h"

static char *slurp(const char *path, long *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "can't open %s\n", path); exit(2); }
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = malloc(n + 1);
  if (fread(b, 1, n, f) != (size_t)n) { fprintf(stderr, "can't read %s\n", path); exit(2); }
  b[n] = 0;
  fclose(f);
  if (len) *len = n;
  return b;
}

static int stopAfter = -1, calls = 0, lastTotal = 0;
static int progress(void *ctx, int done, int total) {
  (void)ctx;
  calls++;
  lastTotal = total;
  return stopAfter >= 0 && done >= stopAfter;
}

int main(int argc, char **argv) {
  if (argc < 4) { fprintf(stderr, "usage: see the top of bridge_test.c\n"); return 2; }
  char err[1024];
  npvf *v = npvf_open(argv[1], err, sizeof err);
  if (!v) { printf("{\"openError\":\"%s\"}\n", err); return 1; }
  char *out = NULL;
  if (!strcmp(argv[2], "call") && argc >= 5) {
    out = npvf_call(v, argv[3], slurp(argv[4], NULL));
  } else if (!strcmp(argv[2], "measure") && argc >= 5) {
    long n;
    unsigned char *w = (unsigned char *)slurp(argv[3], &n);
    long p = 12, data = 0, len = 0;
    uint32_t rate = 48000;
    uint16_t ch = 1;
    while (p + 8 <= n) {
      uint32_t sz; memcpy(&sz, w + p + 4, 4);
      if (!memcmp(w + p, "fmt ", 4)) { memcpy(&ch, w + p + 10, 2); memcpy(&rate, w + p + 12, 4); }
      if (!memcmp(w + p, "data", 4)) { data = p + 8; len = sz; }
      p += 8 + sz + (sz & 1);
    }
    long frames = len / (4 * ch);
    float *mono = malloc(sizeof(float) * (frames ? frames : 1));
    for (long i = 0; i < frames; i++) {
      float s = 0;
      for (int c = 0; c < ch; c++) { float x; memcpy(&x, w + data + (i * ch + c) * 4, 4); s += x; }
      mono[i] = s / ch;
    }
    if (argc >= 6) stopAfter = atoi(argv[5]);
    out = npvf_measure(v, mono, frames, rate, slurp(argv[4], NULL), progress, NULL);
    fprintf(stderr, "progress calls: %d of %d\n", calls, lastTotal);
  } else {
    fprintf(stderr, "unknown command\n");
    return 2;
  }
  printf("%s\n", out);
  npvf_free(out);
  npvf_close(v);
  return 0;
}
