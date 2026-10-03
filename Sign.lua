local ADDON, ns = ...

-- Signatures (0.9.7): what the author's character publishes (the High Council list) carries an
-- RSA signature made on the author's own computer (the signing tool). Every client
-- checks it with the public key below, so anyone may pass a signed list along and nobody can
-- forge or change one. RSA-2048, e = 3, PKCS#1 v1.5 over SHA-256: the whole block is compared
-- byte for byte (no lenient parsing, the known weakness of e = 3).

local Sign = {}
ns.Sign = Sign

local B = _G.bit
local band, bor, bxor, bnot, rshift, lshift = B.band, B.bor, B.bxor, B.bnot, B.rshift, B.lshift
local M32 = 4294967296
local function u(x) return x % M32 end
local function rrot(x, n) return u(bor(rshift(x, n), lshift(x, 32 - n))) end
local function add(...)
	local s = 0
	for i = 1, select("#", ...) do s = s + select(i, ...) end
	return s % M32
end

local K256 = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- SHA-256 of a string, as 32 bytes.
function Sign.SHA256(msg)
	local len = #msg
	msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
	local bits, tail = len * 8, {}
	for i = 7, 0, -1 do tail[#tail + 1] = string.char(math.floor(bits / 2 ^ (8 * i)) % 256) end
	msg = msg .. table.concat(tail)
	local h = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	local w = {}
	for chunk = 1, #msg, 64 do
		for i = 0, 15 do
			local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
			w[i] = ((a * 256 + b) * 256 + c) * 256 + d
		end
		for i = 16, 63 do
			local s0 = u(bxor(rrot(w[i - 15], 7), rrot(w[i - 15], 18), rshift(w[i - 15], 3)))
			local s1 = u(bxor(rrot(w[i - 2], 17), rrot(w[i - 2], 19), rshift(w[i - 2], 10)))
			w[i] = add(w[i - 16], s0, w[i - 7], s1)
		end
		local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
		for i = 0, 63 do
			local S1 = u(bxor(rrot(e, 6), rrot(e, 11), rrot(e, 25)))
			local ch = u(bxor(band(e, f), band(bnot(e), g)))
			local t1 = add(hh, S1, ch, K256[i + 1], w[i])
			local S0 = u(bxor(rrot(a, 2), rrot(a, 13), rrot(a, 22)))
			local maj = u(bxor(band(a, b), band(a, c), band(b, c)))
			local t2 = add(S0, maj)
			hh, g, f, e, d, c, b, a = g, f, e, add(d, t1), c, b, a, add(t1, t2)
		end
		h[1], h[2], h[3], h[4] = add(h[1], a), add(h[2], b), add(h[3], c), add(h[4], d)
		h[5], h[6], h[7], h[8] = add(h[5], e), add(h[6], f), add(h[7], g), add(h[8], hh)
	end
	local out = {}
	for i = 1, 8 do
		local x = h[i]
		out[i] = string.char(math.floor(x / 16777216) % 256, math.floor(x / 65536) % 256, math.floor(x / 256) % 256, x % 256)
	end
	return table.concat(out)
end

-- Big numbers: arrays of 24-bit limbs, least significant first.
local BASE = 16777216
local function Trim(a) while #a > 0 and a[#a] == 0 do a[#a] = nil end return a end
local function FromHex(hex)
	local out = {}
	hex = hex:gsub("^0+", "")
	local i = #hex
	while i > 0 do
		local j = math.max(1, i - 5)
		out[#out + 1] = tonumber(hex:sub(j, i), 16)
		i = j - 1
	end
	return out
end
local function FromBytes(s)
	return FromHex((s:gsub(".", function(c) return ("%02x"):format(c:byte()) end)))
end
local function Cmp(a, b)
	Trim(a); Trim(b)
	if #a ~= #b then return #a < #b and -1 or 1 end
	for i = #a, 1, -1 do if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end end
	return 0
end
local function Mul(a, b)
	local r = {}
	for i = 1, #a + #b do r[i] = 0 end
	for i = 1, #a do
		local carry, ai = 0, a[i]
		for j = 1, #b do
			local t = r[i + j - 1] + ai * b[j] + carry
			carry = math.floor(t / BASE)
			r[i + j - 1] = t - carry * BASE
		end
		r[i + #b] = r[i + #b] + carry
	end
	return Trim(r)
end
local function Sub(a, b) -- a >= b
	local r, borrow = {}, 0
	for i = 1, #a do
		local t = a[i] - (b[i] or 0) - borrow
		if t < 0 then t, borrow = t + BASE, 1 else borrow = 0 end
		r[i] = t
	end
	return Trim(r)
end
local function Shift(a, n) local r = {} for i = n + 1, #a do r[#r + 1] = a[i] end return r end
local function Low(a, n) local r = {} for i = 1, math.min(n, #a) do r[i] = a[i] end return Trim(r) end

-- CHANGEME: the signing key's public half (RSA-2048, e = 3): N and the Barrett constant MU in hex, and
-- K, the limb count. Empty, as here, every signature is refused (no signed list is ever taken).
Sign.N = FromHex("") -- CHANGEME
Sign.MU = FromHex("") -- CHANGEME
Sign.K = 86 -- (a 2048-bit key in 24-bit limbs)

-- x mod N, x < N^2 (Barrett reduction; mu = floor(BASE^(2K) / N) comes with the key).
local function Reduce(x)
	local k, n = Sign.K, Sign.N
	local q = Shift(Mul(Shift(x, k - 1), Sign.MU), k + 1)
	local r1, r2 = Low(x, k + 1), Low(Mul(q, n), k + 1)
	local r
	if Cmp(r1, r2) >= 0 then
		r = Sub(r1, r2)
	else
		local big = {}
		for i = 1, k + 1 do big[i] = r1[i] or 0 end
		big[k + 2] = 1
		r = Sub(big, r2)
	end
	while Cmp(r, n) >= 0 do r = Sub(r, n) end
	return r
end

local PREFIX = "\48\49\48\13\6\9\96\134\72\1\101\3\4\2\1\5\0\4\32"

-- s^3 mod N, the block a signature opens to (0.9.8); nil when sigHex is no number in 1..N-1.
local function Open(sigHex)
	if type(sigHex) ~= "string" or #sigHex > 512 or not sigHex:find("^%x+$") then return nil end
	local s = FromHex(sigHex)
	if #s == 0 or Cmp(s, Sign.N) >= 0 then return nil end
	return Reduce(Mul(Reduce(Mul(s, s)), s))
end

-- The same, in hex (tests check the arithmetic on values whose answer is known).
function Sign.Open(sigHex)
	local m = Open(sigHex)
	if not m then return nil end
	if #m == 0 then return "0" end
	local out = { ("%x"):format(m[#m]) }
	for i = #m - 1, 1, -1 do out[#out + 1] = ("%06x"):format(m[i]) end
	return table.concat(out)
end

-- Is sigHex the author's signature of text? A signature is exactly as long as the key (512
-- hex digits, RFC 8017 8.2.2): one spelling each, as the signing script writes it. Any other
-- length is refused unread (Sign.Plausible: the channel's lists ask no signature check for it).
Sign.HEX = 512
function Sign.Plausible(sigHex)
	return type(sigHex) == "string" and #sigHex == Sign.HEX and sigHex:find("^%x+$") ~= nil
end
function Sign.Verify(text, sigHex)
	if type(text) ~= "string" or not Sign.Plausible(sigHex) then return false end
	local m = Open(sigHex)
	if not m then return false end
	local hash = Sign.SHA256(text)
	local em = "\0\1" .. string.rep("\255", 256 - 3 - #PREFIX - #hash) .. "\0" .. PREFIX .. hash
	return Cmp(m, FromBytes(em)) == 0
end

-- Tests: fn runs with another key (hex N and mu, K limbs, as the signing tool keeps
-- them), the author's comes back after, whatever fn does.
function Sign.WithKey(nHex, muHex, k, fn)
	local n, mu, kk = Sign.N, Sign.MU, Sign.K
	Sign.N, Sign.MU, Sign.K = FromHex((nHex:gsub("^0x", ""))), FromHex((muHex:gsub("^0x", ""))), k
	local ok, err = pcall(fn)
	Sign.N, Sign.MU, Sign.K = n, mu, kk
	if not ok then error(err, 0) end
end
