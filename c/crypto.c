/* Minimal OpenSSL 3 binding; cryptography stays in libcrypto.
 * API references:
 * https://docs.openssl.org/3.0/man3/EVP_DigestInit/
 * https://docs.openssl.org/3.0/man3/EVP_MAC/
 */
#include <lua.h>
#include <lauxlib.h>
#include <openssl/evp.h>
#include <openssl/crypto.h>

#if !defined(OPENSSL_VERSION_MAJOR) || OPENSSL_VERSION_MAJOR < 3
#error "LCA requires OpenSSL 3 or newer development headers"
#endif

static int sha256(lua_State *L) {
    size_t len, outlen = 0;
    unsigned char out[32];
    luaL_checktype(L, 1, LUA_TSTRING);
    const char *data = luaL_checklstring(L, 1, &len);
    if (!EVP_Q_digest(NULL, "SHA256", NULL, data, len, out, &outlen)
        || outlen != sizeof(out))
        return luaL_error(L, "OpenSSL SHA-256 failed");
    lua_pushlstring(L, (const char *)out, outlen);
    return 1;
}

static int hmac_sha256(lua_State *L) {
    size_t keylen, len, outlen = 0;
    unsigned char out[32];
    luaL_checktype(L, 1, LUA_TSTRING);
    luaL_checktype(L, 2, LUA_TSTRING);
    const char *key = luaL_checklstring(L, 1, &keylen);
    const char *data = luaL_checklstring(L, 2, &len);
    if (!EVP_Q_mac(NULL, "HMAC", NULL, "SHA256", NULL, key, keylen,
                   (const unsigned char *)data, len, out, sizeof(out), &outlen)
        || outlen != sizeof(out)) {
        OPENSSL_cleanse(out, sizeof(out));
        return luaL_error(L, "OpenSSL HMAC-SHA-256 failed");
    }
    lua_pushlstring(L, (const char *)out, outlen);
    OPENSSL_cleanse(out, sizeof(out));
    return 1;
}

int luaopen_agent_crypto(lua_State *L) {
    static const luaL_Reg functions[] = {
        {"sha256", sha256}, {"hmac_sha256", hmac_sha256}, {NULL, NULL}
    };
    luaL_newlib(L, functions);
    return 1;
}
