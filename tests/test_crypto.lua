#!/usr/bin/env lua
pcall(require, "luarocks.loader")
local crypto = require("agent.crypto")
local function hex(bytes)
	assert(#bytes == 32)
	return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end
-- Independently generated with Python hashlib/hmac. Include NULs, high bytes,
-- empty keys, keys larger than a SHA-256 block, and a million-byte input.
local vectors = {
	{ "", "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad" },
	{ "key\0\255", "data\0\255", "33476d797dc4aeb6a8c49ce34450f7969dad23b708d2955faa294f03bf1d7440", "d24ee7c99d2a1a0d341f7de99a4dcf291665dfa901093ac64ef66d966a947b6c" },
	{ string.rep("k", 131), string.rep("a", 1000000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "6aa3ede3158d2f44e5c40175e84000fb2fa95eac5c915c7382dd414034fdcf51" },
}
for _, v in ipairs(vectors) do
	assert(hex(crypto.sha256(v[2])) == v[3], "SHA-256 vector mismatch")
	assert(hex(crypto.hmac_sha256(v[1], v[2])) == v[4], "HMAC vector mismatch")
end
for _, bad in ipairs({ false, 42, {} }) do
	assert(not pcall(crypto.sha256, bad))
	assert(not pcall(crypto.hmac_sha256, bad, "data"))
	assert(not pcall(crypto.hmac_sha256, "key", bad))
end
assert(not pcall(crypto.sha256))
assert(not pcall(crypto.hmac_sha256, "key"))
print("crypto vectors and argument checks passed")
