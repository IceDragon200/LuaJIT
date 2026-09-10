/* C API regression check: relocate reallocations and fail each allocation in
** compilation, helper binding, and matching. See test/README.md for building. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"

typedef struct Alloc {
  size_t live, moves;
  unsigned remaining;
  int armed, failed;
} Alloc;

static void *moving_alloc(void *ud, void *ptr, size_t oldsize, size_t newsize)
{
  Alloc *a=(Alloc *)ud;
  void *next;
  if (!newsize) {
    if (ptr) { a->live-=oldsize; free(ptr); }
    return NULL;
  }
  if (a->armed && a->remaining--==0) {
    a->failed=1; a->armed=0; return NULL;
  }
  next=malloc(newsize);
  if (!next) return NULL;
  if (ptr) {
    memcpy(next,ptr,oldsize<newsize ? oldsize : newsize);
    a->live-=oldsize; a->moves++; free(ptr);
  }
  a->live+=newsize;
  return next;
}

static int recover(lua_State *L)
{
  lua_settop(L,0);
  lua_gc(L,LUA_GCCOLLECT,0);
  if (luaL_loadstring(L,"return 42") || lua_pcall(L,0,1,0)) return 0;
  return lua_tointeger(L,-1)==42;
}

int main(void)
{
  char source[8192],packet[89];
  size_t used=0,totalmoves=0;
  unsigned stage,position,i;
  used+=(size_t)snprintf(source+used,sizeof(source)-used,
                         "return function(input,pin) local @b{");
  for (i=1;i<=80;i++)
    used+=(size_t)snprintf(source+used,sizeof(source)-used,"v%u<bytes(1)>,",i);
  used+=(size_t)snprintf(source+used,sizeof(source)-used,
    "n<u8>,tail<bytes(n)>,values<u16[2]>,^pin<bytes(n)>}=input; "
    "local {tag,...rest}={tag=7,keep=values}; "
    "return v1,v80,n,tail,values[1],values[2],rest.keep[2] end");
  memset(packet,'X',80);
  memcpy(packet+80,"\2ok\0\1\0\2ok",9);
  for (stage=0;stage<3;stage++) {
    for (position=0;position<512;position++) {
      Alloc a={0,0,0,0,0};
      lua_State *L=lua_newstate(moving_alloc,&a);
      int status,failed;
      if (!L) return 1;
      if (stage==0) { a.armed=1; a.remaining=position; }
      status=luaL_loadbuffer(L,source,used,"allocator pattern");
      if (stage>0 && status) return 2;
      if (stage==1) { a.armed=1; a.remaining=position; }
      if (stage>0) status=lua_pcall(L,0,1,0);
      if (stage==2) {
        if (status) return 3;
        lua_gc(L,LUA_GCCOLLECT,0);
        lua_pushlstring(L,packet,sizeof(packet));
        lua_pushliteral(L,"ok");
        a.armed=1; a.remaining=position;
        status=lua_pcall(L,2,LUA_MULTRET,0);
      }
      a.armed=0; failed=a.failed;
      if (failed && status!=LUA_ERRMEM) {
        fprintf(stderr,"stage %u allocation %u: expected memory error, got %d\n",
                stage,position,status); return 4;
      }
      if (!failed && status) {
        fprintf(stderr,"%s\n",lua_tostring(L,-1)); return 5;
      }
      if (!failed && stage==2 && (lua_gettop(L)!=7 ||
          strcmp(lua_tostring(L,1),"X") || strcmp(lua_tostring(L,2),"X") ||
          lua_tonumber(L,3)!=2 || strcmp(lua_tostring(L,4),"ok") ||
          lua_tonumber(L,5)!=1 || lua_tonumber(L,6)!=2 || lua_tonumber(L,7)!=2))
        return 6;
      if (!recover(L)) return 7;
      lua_close(L); totalmoves+=a.moves;
      if (a.live) { fprintf(stderr,"allocation leak: %zu bytes\n",a.live); return 8; }
      if (!failed) break;
    }
    if (position==512) return 9;
    printf("PASS: stage %u, %u allocation-failure positions and recovery\n",stage,position);
  }
  if (!totalmoves) return 10;
  printf("PASS: %zu reallocations moved; no allocations retained after close\n",totalmoves);
  return 0;
}
