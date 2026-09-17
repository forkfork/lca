#include <lua.h>
#include <lauxlib.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* The kernel releases the lock on close or process death. Never unlink its
 * path: waiters must keep referring to the same inode. CLOEXEC prevents a
 * spawned command from inheriting ownership. */
static int release(lua_State *L) {
    int *fd = luaL_checkudata(L, 1, "agent.file_lock");
    if (*fd >= 0) { close(*fd); *fd = -1; }
    return 0;
}

static int acquire(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) {
        lua_pushnil(L); lua_pushstring(L, strerror(errno)); return 2;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int error = errno;
        close(fd);
        lua_pushnil(L);
        lua_pushstring(L, (error == EWOULDBLOCK || error == EAGAIN) ? "busy" : strerror(error));
        return 2;
    }
    int *lock = lua_newuserdatauv(L, sizeof(int), 0);
    *lock = fd;
    luaL_setmetatable(L, "agent.file_lock");
    return 1;
}

int luaopen_agent_file_lock(lua_State *L) {
    luaL_newmetatable(L, "agent.file_lock");
    lua_pushcfunction(L, release); lua_setfield(L, -2, "__gc");
    lua_pushcfunction(L, release); lua_setfield(L, -2, "__close");
    lua_pushcfunction(L, release); lua_setfield(L, -2, "close");
    lua_pushvalue(L, -1); lua_setfield(L, -2, "__index");
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, acquire); lua_setfield(L, -2, "acquire");
    return 1;
}
