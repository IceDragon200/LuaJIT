/*
** OpenSSL-backed cryptographic library.
** Local experimental extension. Built only with LJ_OPENSSL=1.
*/

#define lib_crypto_c
#define LUA_LIB

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#if LJ_HAS_OPENSSL

#include <limits.h>
#include <string.h>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>

#include "lj_obj.h"
#include "lj_gc.h"
#include "lj_buf.h"
#include "lj_str.h"
#include "lj_lib.h"

/* ------------------------------------------------------------------------ */


/***
OpenSSL-backed cryptographic primitives for byte strings.
This optional module is available only when LuaJIT is built with `LJ_OPENSSL=1`.
@module crypto
@usage local crypto = require("crypto")
@see doc/ext_crypto.html
*/

static int crypto_name_is(GCstr *name, const char *literal)
{
  size_t len = strlen(literal);
  return name->len == len && memcmp(strdata(name), literal, len) == 0;
}

static const EVP_MD *crypto_md(lua_State *L, int narg)
{
  GCstr *name = lj_lib_checkstr(L, narg);
  if (crypto_name_is(name, "sha256")) return EVP_sha256();
  if (crypto_name_is(name, "sha384")) return EVP_sha384();
  if (crypto_name_is(name, "sha512")) return EVP_sha512();
  luaL_argerror(L, narg, "unsupported hash (expected sha256, sha384, or sha512)");
  return NULL;  /* Silence the compiler. */
}

static void crypto_check_length(lua_State *L, MSize length, MSize expected,
				const char *what)
{
  if (length != expected)
    luaL_error(L, "%s must be %d bytes", what, (int)expected);
}

static int crypto_check_int_length(lua_State *L, GCstr *value,
				   const char *what)
{
  if (value->len > INT_MAX)
    luaL_error(L, "%s is too large", what);
  return (int)value->len;
}

static GCstr *crypto_optional_string(lua_State *L, int narg)
{
  TValue *value = L->base + narg-1;
  if (value >= L->top || tvisnil(value)) return NULL;
  return lj_lib_checkstr(L, narg);
}

static int crypto_openssl_error(lua_State *L, const char *operation)
{
  return luaL_error(L, "OpenSSL %s failed", operation);
}

static int crypto_authentication_failed(lua_State *L)
{
  lua_pushnil(L);
  lua_pushliteral(L, "authentication failed");
  return 2;
}

/***
Read cryptographically strong random bytes from OpenSSL.
@function crypto.random_bytes
@param length non-negative number of bytes to read
@return byte string of exactly `length` bytes
*/
static int lj_cf_crypto_random_bytes(lua_State *L)
{
  int32_t length = lj_lib_checkint(L, 1);
  SBuf *out;
  unsigned char *bytes;

  if (length < 0)
    return luaL_argerror(L, 1, "length must not be negative");
  if (length == 0) {
    setstrV(L, L->top++, lj_str_new(L, "", 0));
    return 1;
  }
  out = lj_buf_tmp_(L);
  bytes = (unsigned char *)lj_buf_need(out, (MSize)length);
  if (length && RAND_bytes(bytes, length) != 1)
    return crypto_openssl_error(L, "random byte generation");
  out->w = out->b + length;
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

/***
Calculate a binary message digest.
Supported algorithms are `sha256`, `sha384`, and `sha512`.
@function crypto.hash
@param algorithm supported digest algorithm name
@param data byte string to hash
@return binary digest bytes
*/
static int lj_cf_crypto_hash(lua_State *L)
{
  const EVP_MD *md = crypto_md(L, 1);
  GCstr *data = lj_lib_checkstr(L, 2);
  EVP_MD_CTX *ctx = EVP_MD_CTX_new();
  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int length = 0;

  if (!ctx) return crypto_openssl_error(L, "hash initialization");
  if (EVP_DigestInit_ex(ctx, md, NULL) != 1 ||
      EVP_DigestUpdate(ctx, strdata(data), data->len) != 1 ||
      EVP_DigestFinal_ex(ctx, digest, &length) != 1) {
    EVP_MD_CTX_free(ctx);
    return crypto_openssl_error(L, "hash calculation");
  }
  EVP_MD_CTX_free(ctx);
  setstrV(L, L->top++, lj_str_new(L, (const char *)digest, length));
  lj_gc_check(L);
  return 1;
}

/***
Calculate a binary HMAC.
Supported algorithms are `sha256`, `sha384`, and `sha512`.
@function crypto.hmac
@param algorithm supported digest algorithm name
@param key secret key bytes
@param data byte string to authenticate
@return binary MAC bytes
*/
static int lj_cf_crypto_hmac(lua_State *L)
{
  const EVP_MD *md = crypto_md(L, 1);
  GCstr *key = lj_lib_checkstr(L, 2);
  GCstr *data = lj_lib_checkstr(L, 3);
  unsigned char mac[EVP_MAX_MD_SIZE];
  unsigned int length = 0;

  if (!HMAC(md, strdata(key), crypto_check_int_length(L, key, "HMAC key"),
	    (const unsigned char *)strdata(data), data->len, mac, &length))
    return crypto_openssl_error(L, "HMAC calculation");
  setstrV(L, L->top++, lj_str_new(L, (const char *)mac, length));
  lj_gc_check(L);
  return 1;
}

/***
Derive key material with HKDF.
Supported algorithms are `sha256`, `sha384`, and `sha512`; output length is
limited to 255 digest lengths as required by HKDF.
@function crypto.hkdf
@param algorithm supported digest algorithm name
@param ikm input key material bytes
@param salt salt bytes
@param info context bytes
@param length requested output byte length
@return derived key bytes
*/
static int lj_cf_crypto_hkdf(lua_State *L)
{
  const EVP_MD *md = crypto_md(L, 1);
  GCstr *ikm = lj_lib_checkstr(L, 2);
  GCstr *salt = lj_lib_checkstr(L, 3);
  GCstr *info = lj_lib_checkstr(L, 4);
  int32_t length = lj_lib_checkint(L, 5);
  EVP_PKEY_CTX *ctx;
  SBuf *out;
  unsigned char *bytes;
  size_t output_length;
  int max_length;
  int ikm_length;
  int salt_length;
  int info_length;

  if (length < 0)
    return luaL_argerror(L, 5, "length must not be negative");
  max_length = 255 * EVP_MD_size(md);
  if (length > max_length)
    return luaL_argerror(L, 5, "length exceeds the HKDF limit for this hash");
  if (length == 0) {
    setstrV(L, L->top++, lj_str_new(L, "", 0));
    return 1;
  }
  ikm_length = crypto_check_int_length(L, ikm, "HKDF input key material");
  salt_length = crypto_check_int_length(L, salt, "HKDF salt");
  info_length = crypto_check_int_length(L, info, "HKDF info");
  ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, NULL);
  if (!ctx) return crypto_openssl_error(L, "HKDF initialization");
  if (EVP_PKEY_derive_init(ctx) <= 0 ||
      EVP_PKEY_CTX_set_hkdf_md(ctx, md) <= 0 ||
      EVP_PKEY_CTX_set1_hkdf_salt(ctx, (const unsigned char *)strdata(salt),
		salt_length) <= 0 ||
      EVP_PKEY_CTX_set1_hkdf_key(ctx, (const unsigned char *)strdata(ikm),
		ikm_length) <= 0 ||
      EVP_PKEY_CTX_add1_hkdf_info(ctx, (const unsigned char *)strdata(info),
		info_length) <= 0) {
    EVP_PKEY_CTX_free(ctx);
    return crypto_openssl_error(L, "HKDF initialization");
  }
  out = lj_buf_tmp_(L);
  bytes = (unsigned char *)lj_buf_need(out, (MSize)length);
  output_length = (size_t)length;
  if (EVP_PKEY_derive(ctx, bytes, &output_length) <= 0 ||
      output_length != (size_t)length) {
    EVP_PKEY_CTX_free(ctx);
    return crypto_openssl_error(L, "HKDF derivation");
  }
  EVP_PKEY_CTX_free(ctx);
  out->w = out->b + output_length;
  setstrV(L, L->top++, lj_buf_str(L, out));
  lj_gc_check(L);
  return 1;
}

/***
Compare two byte strings without early exit for equal-length inputs.
@function crypto.constant_time_equal
@param left byte string
@param right byte string
@return boolean equality result
*/
static int lj_cf_crypto_constant_time_equal(lua_State *L)
{
  GCstr *left = lj_lib_checkstr(L, 1);
  GCstr *right = lj_lib_checkstr(L, 2);
  int equal = left->len == right->len &&
	      (!left->len || CRYPTO_memcmp(strdata(left), strdata(right), left->len) == 0);
  setboolV(L->top++, equal);
  return 1;
}

static const EVP_CIPHER *crypto_aead_cipher(lua_State *L, int narg)
{
  GCstr *name = lj_lib_checkstr(L, narg);
  if (crypto_name_is(name, "aes-256-gcm")) return EVP_aes_256_gcm();
  if (crypto_name_is(name, "chacha20-poly1305")) return EVP_chacha20_poly1305();
  luaL_argerror(L, narg,
	"unsupported AEAD (expected aes-256-gcm or chacha20-poly1305)");
  return NULL;  /* Silence the compiler. */
}

static void crypto_aead_inputs(lua_State *L, int keyarg, int noncearg,
			       GCstr **pkey, GCstr **pnonce)
{
  GCstr *key = lj_lib_checkstr(L, keyarg);
  GCstr *nonce = lj_lib_checkstr(L, noncearg);
  crypto_check_length(L, key->len, 32, "AEAD key");
  crypto_check_length(L, nonce->len, 12, "AEAD nonce");
  *pkey = key;
  *pnonce = nonce;
}

/***
Encrypt and authenticate bytes with an AEAD cipher.
Supported ciphers are `aes-256-gcm` and `chacha20-poly1305`. Keys must be 32
bytes and nonces must be 12 bytes.
@function crypto.aead_encrypt
@param cipher supported AEAD cipher name
@param key 32-byte secret key
@param nonce 12-byte nonce; callers must prevent reuse for a key
@param plaintext byte string to encrypt
@param[opt] aad associated-data byte string
@return ciphertext, 16-byte authentication tag
*/
static int lj_cf_crypto_aead_encrypt(lua_State *L)
{
  const EVP_CIPHER *cipher = crypto_aead_cipher(L, 1);
  GCstr *key, *nonce, *plaintext, *aad;
  EVP_CIPHER_CTX *ctx;
  SBuf *out;
  unsigned char *ciphertext;
  unsigned char tag[16];
  int length, final_length;
  MSize ciphertext_length;

  crypto_aead_inputs(L, 2, 3, &key, &nonce);
  plaintext = lj_lib_checkstr(L, 4);
  aad = crypto_optional_string(L, 5);
  if (plaintext->len > INT_MAX || (aad && aad->len > INT_MAX))
    return luaL_error(L, "AEAD input is too large");
  ctx = EVP_CIPHER_CTX_new();
  if (!ctx) return crypto_openssl_error(L, "AEAD initialization");
  if (EVP_EncryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonce->len, NULL) != 1 ||
      EVP_EncryptInit_ex(ctx, NULL, NULL, (const unsigned char *)strdata(key),
		(const unsigned char *)strdata(nonce)) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD initialization");
  }
  if (aad && aad->len &&
      EVP_EncryptUpdate(ctx, NULL, &length, (const unsigned char *)strdata(aad),
		(int)aad->len) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD associated-data processing");
  }
  out = lj_buf_tmp_(L);
  ciphertext = (unsigned char *)lj_buf_need(out, plaintext->len + EVP_MAX_BLOCK_LENGTH);
  if (EVP_EncryptUpdate(ctx, ciphertext, &length,
	(const unsigned char *)strdata(plaintext), (int)plaintext->len) != 1 ||
      EVP_EncryptFinal_ex(ctx, ciphertext + length, &final_length) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, sizeof(tag), tag) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD encryption");
  }
  EVP_CIPHER_CTX_free(ctx);
  ciphertext_length = (MSize)(length + final_length);
  if (!lua_checkstack(L, 2))
    return luaL_error(L, "stack overflow");
  setstrV(L, L->top++, lj_str_new(L, (const char *)ciphertext, ciphertext_length));
  setstrV(L, L->top++, lj_str_new(L, (const char *)tag, sizeof(tag)));
  lj_gc_check(L);
  return 2;
}

/***
Verify and decrypt AEAD ciphertext.
Authentication failure returns `nil, "authentication failed"` rather than
plaintext. The cipher, key, and nonce constraints match `crypto.aead_encrypt`.
@function crypto.aead_decrypt
@param cipher supported AEAD cipher name
@param key 32-byte secret key
@param nonce 12-byte nonce
@param ciphertext byte string to decrypt
@param[opt] aad associated-data byte string when a tag follows
@param tag 16-byte authentication tag
@return plaintext, or nil and an authentication-failure message
*/
static int lj_cf_crypto_aead_decrypt(lua_State *L)
{
  const EVP_CIPHER *cipher = crypto_aead_cipher(L, 1);
  GCstr *key, *nonce, *ciphertext_input, *aad, *tag;
  EVP_CIPHER_CTX *ctx;
  SBuf *out;
  unsigned char *plaintext;
  int length, final_length;
  MSize plaintext_length;

  crypto_aead_inputs(L, 2, 3, &key, &nonce);
  ciphertext_input = lj_lib_checkstr(L, 4);
  if (L->base + 5 < L->top) {
    aad = crypto_optional_string(L, 5);
    tag = lj_lib_checkstr(L, 6);
    crypto_check_length(L, tag->len, 16, "AEAD tag");
  } else {
    aad = NULL;
    tag = lj_lib_checkstr(L, 5);
    crypto_check_length(L, tag->len, 16, "AEAD tag");
  }
  if (ciphertext_input->len > INT_MAX || (aad && aad->len > INT_MAX))
    return luaL_error(L, "AEAD input is too large");
  ctx = EVP_CIPHER_CTX_new();
  if (!ctx) return crypto_openssl_error(L, "AEAD initialization");
  if (EVP_DecryptInit_ex(ctx, cipher, NULL, NULL, NULL) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, (int)nonce->len, NULL) != 1 ||
      EVP_DecryptInit_ex(ctx, NULL, NULL, (const unsigned char *)strdata(key),
		(const unsigned char *)strdata(nonce)) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD initialization");
  }
  if (aad && aad->len &&
      EVP_DecryptUpdate(ctx, NULL, &length, (const unsigned char *)strdata(aad),
	(int)aad->len) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD associated-data processing");
  }
  out = lj_buf_tmp_(L);
  plaintext = (unsigned char *)lj_buf_need(out,
		ciphertext_input->len + EVP_MAX_BLOCK_LENGTH);
  if (EVP_DecryptUpdate(ctx, plaintext, &length,
	(const unsigned char *)strdata(ciphertext_input),
	(int)ciphertext_input->len) != 1 ||
      EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, (int)tag->len,
		(void *)strdata(tag)) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_openssl_error(L, "AEAD decryption");
  }
  if (EVP_DecryptFinal_ex(ctx, plaintext + length, &final_length) != 1) {
    EVP_CIPHER_CTX_free(ctx);
    return crypto_authentication_failed(L);
  }
  EVP_CIPHER_CTX_free(ctx);
  plaintext_length = (MSize)(length + final_length);
  setstrV(L, L->top++, lj_str_new(L, (const char *)plaintext, plaintext_length));
  lj_gc_check(L);
  return 1;
}

/* ------------------------------------------------------------------------ */

/* These extensions use ordinary C functions, without fast-function IDs. */
static const luaL_Reg crypto_funcs[] = {
  {"random_bytes", lj_cf_crypto_random_bytes},
  {"hash", lj_cf_crypto_hash},
  {"hmac", lj_cf_crypto_hmac},
  {"hkdf", lj_cf_crypto_hkdf},
  {"constant_time_equal", lj_cf_crypto_constant_time_equal},
  {"aead_encrypt", lj_cf_crypto_aead_encrypt},
  {"aead_decrypt", lj_cf_crypto_aead_decrypt},
  {NULL, NULL}
};

LUALIB_API int luaopen_crypto(lua_State *L)
{
  luaL_register(L, LUA_CRYPTOLIBNAME, crypto_funcs);
  return 1;
}

#endif
