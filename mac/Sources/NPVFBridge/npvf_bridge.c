/*
 * The bridge: one Lua state per npvf, the app's Lua loaded into it, and two
 * C functions handed to the measurer - read(t, n) for samples and
 * progress(i, n) for stopping. See include/npvf_bridge.h.
 */
#include "npvf_bridge.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

struct npvf {
  lua_State *L;
};

typedef struct {
  const float *mono;
  long frames;
  double fs;
  npvf_progress progress;
  void *context;
} render;

static char *dup_string(const char *s, size_t n) {
  char *out = (char *)malloc(n + 1);
  if (!out) return NULL;
  memcpy(out, s, n);
  out[n] = 0;
  return out;
}

static char *error_json(const char *msg) {
  /* {"error":"..."} with quotes, backslashes and control characters escaped */
  size_t n = strlen(msg);
  char *out = (char *)malloc(n * 6 + 16);
  if (!out) return NULL;
  char *p = out;
  p += sprintf(p, "{\"error\":\"");
  for (size_t i = 0; i < n; i++) {
    unsigned char c = (unsigned char)msg[i];
    if (c == '"' || c == '\\') { *p++ = '\\'; *p++ = (char)c; }
    else if (c < 0x20) p += sprintf(p, "\\u%04x", c);
    else *p++ = (char)c;
  }
  sprintf(p, "\"}");
  return out;
}

npvf *npvf_open(const char *dir, char *err, size_t errlen) {
  npvf *v = (npvf *)calloc(1, sizeof(npvf));
  if (!v) { snprintf(err, errlen, "out of memory"); return NULL; }
  v->L = luaL_newstate();
  if (!v->L) { free(v); snprintf(err, errlen, "couldn't start Lua"); return NULL; }
  luaL_openlibs(v->L);
  size_t n = strlen(dir);
  char *path = (char *)malloc(n + 32);
  if (!path) { npvf_close(v); snprintf(err, errlen, "out of memory"); return NULL; }
  sprintf(path, "%s%snpvf_app.lua", dir, (n && dir[n - 1] == '/') ? "" : "/");
  int rc = luaL_dofile(v->L, path);
  free(path);
  if (rc != LUA_OK) {
    snprintf(err, errlen, "%s", lua_tostring(v->L, -1));
    npvf_close(v);
    return NULL;
  }
  lua_settop(v->L, 0);
  return v;
}

void npvf_close(npvf *v) {
  if (!v) return;
  if (v->L) lua_close(v->L);
  free(v);
}

void npvf_free(char *s) { free(s); }

static char *take_result(lua_State *L, int rc) {
  size_t len = 0;
  const char *s = lua_tolstring(L, -1, &len);
  char *out;
  if (rc != LUA_OK) out = error_json(s ? s : "Lua error");
  else if (!s) out = error_json("no result");
  else out = dup_string(s, len);
  lua_settop(L, 0);
  return out;
}

char *npvf_call(npvf *v, const char *fn, const char *argsJson) {
  lua_State *L = v->L;
  lua_getglobal(L, "npvf_dispatch");
  lua_pushstring(L, fn);
  lua_pushstring(L, argsJson ? argsJson : "{}");
  int rc = lua_pcall(L, 2, 1, 0);
  return take_result(L, rc);
}

/* read(t, n): n mono samples from t seconds into the render, zeros outside it */
static int l_read(lua_State *L) {
  render *r = (render *)lua_touserdata(L, lua_upvalueindex(1));
  double t = luaL_checknumber(L, 1);
  lua_Integer n = luaL_checkinteger(L, 2);
  if (n < 0) n = 0;
  long s0 = (long)floor(t * r->fs + 0.5);
  lua_createtable(L, (int)n, 0);
  for (lua_Integer i = 0; i < n; i++) {
    long k = s0 + (long)i;
    lua_pushnumber(L, (k >= 0 && k < r->frames) ? (lua_Number)r->mono[k] : 0.0);
    lua_rawseti(L, -2, i + 1);
  }
  return 1;
}

/* progress(i, n): asks the app; non-zero means stop */
static int l_progress(lua_State *L) {
  render *r = (render *)lua_touserdata(L, lua_upvalueindex(1));
  int done = (int)luaL_checkinteger(L, 1), total = (int)luaL_checkinteger(L, 2);
  if (r->progress && r->progress(r->context, done, total)) {
    lua_pushstring(L, "stopped"); /* no "file:line:" in front, so the app can recognise it */
    return lua_error(L);
  }
  return 0;
}

char *npvf_measure(npvf *v, const float *mono, long frames, double fs,
                   const char *requestJson, npvf_progress progress, void *context) {
  lua_State *L = v->L;
  render r = { mono, frames, fs, progress, context };
  lua_getglobal(L, "npvf_measure");
  lua_pushstring(L, requestJson ? requestJson : "{}");
  lua_pushlightuserdata(L, &r);
  lua_pushcclosure(L, l_read, 1);
  lua_pushnumber(L, fs);
  lua_pushlightuserdata(L, &r);
  lua_pushcclosure(L, l_progress, 1);
  int rc = lua_pcall(L, 4, 1, 0);
  return take_result(L, rc);
}
