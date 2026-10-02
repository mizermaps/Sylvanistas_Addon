local ADDON, ns = ...
local L = ns.L

-- Sylvanistas Link (0.9.10): a character's Discord role, proved by players in game.
-- The Sylvanistas bot on Discord gives a player a code: OLC2.<R>.<username>.<exp>.<mode>.<T>.<sig>,
-- signed with the bot's Ed25519 key (ns.LINK_BACKEND_KEYS, Ed25519.lua checks it). /syl discord
-- <code> checks that signature and the expiry, shows the Discord account the code belongs to, and
-- after the player's Accept (nothing is sent before it) asks confirmers in game for proofs that
-- this character asked: each proof is an Ed25519 signature made by a confirmer's addon with a key
-- of its own, kept for one character (SylvanistasDB.discord.keys[Name-Realm]), and certified for that
-- character: OLK2, a signature on the key's public half, its tier and the character's name, by the
-- bot. The bot's keeper makes every key, a High Councillor's too (scripts/link-keys.py confirmer),
-- typed in game with /syl discord key and /syl discord cert. (The council authority's path, where a
-- councillor's addon makes its own key and the author's client certifies it by itself, is below,
-- off unless the author turns it on: ns.LINK_COUNCIL_AUTHORITY, Konig's review.) Nothing of it is
-- made, typed, announced or used before the bot is ready (Link.BotReady). The server stamps who
-- whispers whom, so a proof names the character that really asked, and a certificate is honoured
-- only from the character it names.
-- Who confirms:
--   * a High Councillor (the signed list, Workshop.lua) with a certificate of tier c: one proof is
--     enough; the next councillor online is asked too, and up to two councillors' proofs travel;
--   * mode "a" only, none online: verified players (tier p) drawn for this code. T, in the code,
--     is the bot's threshold: a key is drawn when the first 8 hex of SHA-256(R~keyId) are below T
--     (T is the place of the (M+1)th lowest key, so the M lowest are drawn: the Worker's rule).
--     Five drawn ones at once, lowest first, three must confirm, from three keys.
-- Each confirmer says how it knows the requester's guild (gv, signed): "r" it is its own guild and
-- its roster lists them, "w" its /who saw them in that guild within 15 minutes (Who.lua), "c" only
-- claimed. With enough proofs that only claim it, the request stays open CLAIMED_WAIT (10 minutes)
-- for one that knows it: a councillor who said "c" is asked again (its /who may have run since),
-- and players as they come online; only then does it finish with the guild claimed, and says so.
-- The code's signature never leaves the command the player pasted: the link carries a tag instead,
-- the first 16 hex of SHA-256(<code's signature>~<requester>), which the confirmers sign and the bot
-- recomputes. Someone who sees R (a QR code on a stream) can't make a link for their character.
-- The finished proof reaches the bot two ways: the Sylvanistas Link page reads it from this window
-- (a QR code, or the link in the copy box), or the addon hands it to a watcher (a High Councillor
-- in watcher mode) the next time both are online, whose SavedVariables the bot's keeper uploads.
-- One rule for how long (all from the code's expiry, exp): the bot takes a link until exp + GRACE
-- (7 days); the addon hands it to a watcher until exp + DELIVER_UNTIL (5 days), leaving the keeper
-- 2 days to upload; a watcher keeps what it got until exp + GRACE (it takes exp as the latest
-- proof's time + a code's life, never earlier than exp); the window shows it until exp + GRACE.
-- Messages (Comm.lua; each dispatched only as "<type>~"):
--   DV~1~<certificate>   a confirmer is online (CHANNEL, every 5 minutes); DV~0 its key is gone
--   DR~<nonce>~<guild>~<faction>~<R>~<tag>   a request (WHISPER, requester -> confirmer)
--   DA~<issued>~<keyId>~<gv>~<sig>          a proof (WHISPER, confirmer -> requester)
--   DW~1 | DW~0          a watcher is online, or not any more (CHANNEL, every 5 minutes)
--   DB~<bundle>          a finished proof (WHISPER, requester -> watcher; in Codec.Chunk pieces
--                        "DB~C<id>:<i>:<n>:<piece>" when longer than one message)
--   DK~<R>               the watcher kept it (WHISPER, watcher -> requester)
--   DC~1~<public key>    a councillor's addon asks the author's for a certificate (WHISPER; only
--                        with ns.LINK_COUNCIL_AUTHORITY on, off by default)
--   DE~<certificate>     the author's addon answers it (WHISPER; the same)
-- Certificate: OLK2.<keyId>.<public key, base64url>.<tier c|p>.<exp>.<Name-Realm>.<sig>, a
-- signature over all but the last field (UTF-8) by one of the bot's keys, or, tier c only and for a
-- key whose id is the first 12 hex of SHA-256(<its 32 bytes>), by one of the council authority's
-- (ns.LINK_CA_KEYS). The character is read from both ends (it may hold dots).
-- Signed: OLY4~<requester>~<guild>~<gv>~<faction>~<nonce>~<R>~<tag>~<issued>~<keyId>~<confirmer>
-- Carried: OLB5~<requester>~<guild>~<faction>~<nonce>~<R>~<tag>~<proof>;... (4 proofs at most),
-- each proof <issued>,<keyId>,<confirmer>,<gv>,<sig>,<public key>,<tier>,<certificate's exp>,
-- <certificate's sig>: its certificate travels with it (OLK2.<keyId>.<public key>.<tier>.<exp>.
-- <confirmer>.<certificate's sig>), so a watcher and the bot check it without having heard it. In
-- the URL <ns.LINK_SITE>#b=<the bundle, URL-encoded>: a fragment, never sent to any server.
-- A watcher's inbox (SavedVariables): SylvanistasDB.discord.inbox[R][sender] = { bundle, from, t, keep },
-- only links whose every proof checks with its certificate and that are enough for the bot, one per
-- sender (its latest), and no cap per code: R is public.
-- The author's client records every certificate it signs as the council authority:
-- SylvanistasDB.discord.certified[keyId] = { name, pub, exp, t } (a key for one character only).
-- A confirmer's key never leaves SylvanistasDB.discord.keys, nor the council authority's seed
-- ns.LINK_CA_SEED: neither is ever printed, sent, logged, or written in /syl status and the bug report.

-- The Sylvanistas bot's public keys (64 hex digits each, from scripts/link-keys.py backend): a code
-- or certificate signed by any of them is accepted, so two can be listed while the key changes.
-- Anything that is not 64 hex digits is ignored: until the bot's key is pasted here, every code
-- is refused, and no confirmer key is made, typed, announced or used, nor any certificate asked
-- for, signed or typed (Link.BotReady).
ns.LINK_BACKEND_KEYS = { "PASTE-THE-BOT-PUBLIC-KEY-HEX-HERE" }
-- The High Council's certificate authority (scripts/link-keys.py ca, on the author's computer):
-- its public keys (64 hex digits each), whose certificates of tier c count for councillors' keys.
-- Its seed is only in dist/LinkCA.lua (ns.LINK_CA_SEED), copied to the author's own game and never
-- published. Its certificates count, and councillors' addons make a key and ask for one, only
-- with the author's switch below on and the bot's key pasted above.
ns.LINK_CA_KEYS = { "PASTE-THE-COUNCIL-AUTHORITY-PUBLIC-KEY-HEX-HERE" } -- (CHANGEME: the Olympus author's key was here)
-- The author's switch for the council authority's path (Konig's review): off. Off, every
-- confirmer's key, a High Councillor's too, is one the bot's keeper makes (scripts/link-keys.py
-- confirmer) and the bot certifies, typed in game with /syl discord key <id> <key> and
-- /syl discord cert <certificate>: no addon makes a key of its own, asks the author's client for a
-- certificate or signs one, and no addon takes the authority's certificates (the key that signs
-- them stays listed above, for the day it is turned on). Why: a key made in game draws on tens of
-- bits the client can't hide (Link.EntropySample says which), sits in plain text in the
-- SavedVariables, and its certificate lasts a year. On (true), the path below ("High Councillors'
-- keys, certified by the author's client") runs as it was written, once the bot is ready
-- (Link.BotReady); the bot's keeper then sets LINK_CA_PUBLIC in the Worker too (web/WORKER.md,
-- step 1b). Keys it made are dropped at login while it is off (Link.Resume).
ns.LINK_COUNCIL_AUTHORITY = false
-- The Sylvanistas Link page, a static page on this repository's GitHub Pages (web/public/, its address
-- also in web/public/config.js as PAGE_URL): the QR code and the copy box open it with the link in
-- the #fragment only, which no server ever gets. The page sends the link to the bot's Worker.
ns.LINK_SITE = "https://CHANGEME-your-site.example/sylvanistas-link/"
-- Whose watcher the texts name ("<name>'s watcher"); nil: "the bot's watcher".
ns.LINK_WATCHER_OWNER = nil

local Link = {}
ns.Link = Link
local Ed = ns.Ed25519

Link.CODE_TTL_MAX = 7 * 86400 -- a code valid for longer than this is refused (the bot's are 24 h)
Link.ANNOUNCE_EVERY = 300    -- a confirmer (DV) and a watcher (DW) say they are online this often...
Link.ANNOUNCE_FRESH = 700    -- ...and count as online this long after
Link.COUNCIL_WAIT = 10       -- each High Councillor asked has this long to answer
Link.COUNCIL_AGAIN = 600     -- a councillor who did not answer is asked again after this long
Link.COUNCIL_PROOFS = 2      -- councillors' proofs carried at most
Link.DRAW_FIRST = 5          -- players asked at once
Link.DRAW_MAX = 10           -- ...and at most this many in one round
Link.DRAW_WAIT = 30          -- each batch has this long to answer
Link.NEEDED = 3              -- players' proofs that make a link
Link.MAX_PROOFS = 4          -- proofs carried at most
Link.FRESH = 240             -- players' proofs count together within 4 minutes (the bot: 5)
Link.MORE_WAIT = 60          -- one councillor's proof that showed the guild: a second councillor
                             -- online is asked this long at most
Link.CLAIMED_WAIT = 600      -- enough proofs, none that showed the guild: open this long for one...
Link.CLAIMED_AGAIN = 180     -- ...a councillor whose proof said "c" asked again this often
Link.ASK_AGAIN = 300         -- a player who did not answer is asked again after this long
Link.ROUND_GAP = 120         -- a new round at most this often
Link.CODE_LIFE = 86400       -- the bot's codes live a day (the Worker's TOKEN_LIFE): issued at exp - this
Link.CLOCK_SKEW = 300        -- one game server's clock against another's (the Worker's CLOCK_SKEW)
Link.GRACE = 7 * 86400       -- the bot takes a link until its code's expiry + this (DELIVERY_GRACE)...
Link.KEEPER_TIME = 2 * 86400 -- ...so the addon hands it to a watcher until 2 days before, for the
Link.DELIVER_UNTIL = Link.GRACE - Link.KEEPER_TIME -- keeper to upload it in time (exp + 5 days)
Link.ACK_WAIT = 30           -- a watcher has this long to say it kept the proof
Link.GIVE_GAP = 60           -- a confirmer: one proof per requesting character a minute...
Link.GIVE_DAY = 5            -- ...five a day...
Link.GIVE_MINUTE = 30        -- ...and thirty a minute in all
Link.WHO_FRESH = 15 * 60     -- a /who this recent tells a confirmer the requester's guild ("w")
Link.INBOX_MAX = 500         -- a watcher keeps this many proofs (a new sender past it is refused)...
Link.INBOX_PER_SENDER = 1    -- ...and this many of one sender: its newest replaces its oldest
Link.INBOX_GAP = 60          -- one link checked per requesting character a minute...
Link.INBOX_CHECKS = 2        -- ...and this many at once
Link.MAX_ANNOUNCERS = 3000
Link.CERT_JOBS = 4           -- confirmers' certificates checked at once
Link.CERT_CACHE = 1000       -- checked certificates remembered
Link.CERT_NEW_GAP = 60       -- one new certificate per announcing character a minute is taken
Link.MAX_BUNDLE = 2400       -- bytes of a link at most (four proofs with their certificates)
Link.MAX_CERT = 240          -- ...and of a certificate (DV and DE carry it in one message)
Link.CA_GAP = 600            -- the council authority: one certificate per councillor in this long...
Link.CA_HOUR = 20            -- ...and this many an hour in all
Link.CA_DAYS = 365           -- ...each good for this many days
Link.CA_LOG_MAX = 2000       -- ...and a record of this many kept (the author's SavedVariables)
Link.CA_WAIT = 60            -- a councillor's addon waits this long for the author's certificate,
Link.CA_AGAIN = 600          -- ...and asks again after a refusal (or no answer) this long after
Link.ENTROPY_FRAMES = 8      -- a councillor's new key: the entropy pool is stirred over this many frames
Link.M_MAX_BYTES = 412       -- the longest link a version 15 QR code holds at level M
Link.QUIET = 4               -- modules of white around the code
Link.CHROME = 190            -- UI units of the window around the code (title, name, hint, box)

local req                  -- this character's request while it waits: { rec, asked, told, round... }
local announcers, nAnnouncers = {}, 0 -- [Name-Realm] = { id, tier, pub, exp, cert, t }
local certs, nCerts = {}, 0          -- [certificate] = true | false: signed by the bot or not
local certJobs, nCertJobs = {}, 0    -- certificates being checked
local ownCert              -- { cert, seed, ok }: our own certificate, checked this session
local ownChecking          -- the certificate and seed being checked
local certNewAt = {}       -- [Name-Realm] = when a new certificate of theirs was last taken
local watchers = {}        -- [Name-Realm] = t: High Councillors in watcher mode heard
local delivery             -- the proof on its way to a watcher: { to, due }
local waitWatcher = false  -- a delivery went unanswered: the next one when a watcher is heard
local sentTo = {}          -- watchers our proof was sent to, this session
local recent = {}          -- when our key confirmed, the last minute (every requester)
local inboxTried = {}      -- watcher: [requester] = when their last link was checked
local checking, nChecking = {}, 0 -- watcher: [requester] = true while their link is checked
local inAsm = ns.Codec.NewAssembler() -- watcher: proofs arriving in pieces
local bundleId = 0
local stats = { confirmed = 0, refused = 0, kept = 0, badProofs = 0, badCerts = 0, badBundles = 0, certified = 0 }
local lastAnnounce, lastWatch, lastPrune = -math.huge, -math.huge, -math.huge
local announced            -- the certificate we announced this session (DV~0 when we stop)
local pubCache             -- { id, seed, pub }: our confirmer key's public half
local toldCert = false     -- our saved certificate was found wrong: said once a session
local making               -- a councillor's new key being made: { samples, me }
local auto = {}            -- a councillor's key and the author: { askedAt, refusedAt }
local ca = { given = {}, hour = {} } -- the council authority: [councillor] = when certified; this hour's
local caPub                -- its public key (32 bytes) once found in ns.LINK_CA_KEYS; false: it is not
local frame                -- the Sylvanistas Link window, built the first time it opens
local qr = {}              -- the QR code last made: { url, matrix, level }
local qrJob                -- the URL whose QR code is being made

-- The server's clock (codes and proofs carry the server's time), else ours.
local function ServerTime()
	local t = GetServerTime and GetServerTime()
	return math.floor(tonumber(t) or ns.Now())
end
Link.ServerTime = ServerTime

---------------------------------------------------------------------------
-- Formats: what a field may hold, the code, the certificate, the signed text and the carried link
---------------------------------------------------------------------------

local FACTIONS = { Alliance = true, Horde = true }
local GV = { r = true, w = true, c = true }

-- A field of the signed text: never empty, no separator (~ ; ,), pipe or control byte.
local function Field(s, max)
	return type(s) == "string" and s ~= "" and #s <= max and not s:find("[~|;,%c]")
end
-- "Name-Realm" as ns.FullName writes it (the name may hold spaces and accented letters).
function Link.ValidName(s) return Field(s, 64) and s:find("^[^%-].*%-[^%-%s]+$") ~= nil end
function Link.ValidGuild(s) return Field(s, 40) end
local function Hex(s, n) return type(s) == "string" and #s == n and not s:find("[^0-9a-f]") end
local function Nonce(s) return Hex(s, 16) end
local function Tag(s) return Hex(s, 16) end
local function Threshold(s) return Hex(s, 8) end
local function KeyId(s) return type(s) == "string" and #s >= 6 and #s <= 16 and not s:find("[^a-z0-9]") end
local function Code(s) return type(s) == "string" and #s == 10 and not s:find("[^0-9A-HJKMNP-TV-Z]") end
local function Time(s) return type(s) == "string" and #s <= 12 and s:find("^[1-9]%d*$") ~= nil end
local function User(s) return type(s) == "string" and #s >= 2 and #s <= 32 and not s:find("[^a-z0-9_%.]") end
local function B64(s, n) return type(s) == "string" and #s == n and not s:find("[^A-Za-z0-9_%-]") and Ed.FromB64(s) ~= nil end
-- A signature: 86 characters of base64url that are exactly 64 bytes.
local function Sig(s) return B64(s, 86) end
-- A public key: 43 characters of base64url that are exactly 32 bytes.
local function Pub(s) return B64(s, 43) end
Link.KeyId, Link.Code, Link.Sig = KeyId, Code, Sig

-- What the player pasted may be the bot's whole line: "/syl discord <code>" (or /sylvanistas).
local COMMANDS = { "/syl discord", "/sylvanistas discord" }
local function WithoutCommand(s)
	local lower = s:lower()
	for _, cmd in ipairs(COMMANDS) do
		if lower:sub(1, #cmd) == cmd and s:sub(#cmd + 1, #cmd + 1):find("^%s") then return s:sub(#cmd + 2) end
	end
	return s
end

-- The code the bot gave, as pasted (spaces around it, and the command before it, are fine):
-- { R, user, exp, mode, T, sig, signed } or nil. The username may hold dots: the fields are read
-- from both ends.
function Link.ParseToken(s)
	if type(s) ~= "string" or #s > 400 then return nil end
	s = WithoutCommand(s:match("^%s*(.-)%s*$")):match("^%s*(.-)%s*$")
	if #s > 200 then return nil end
	local R, user, exp, mode, T, sig = s:match("^OLC2%.([^.]*)%.(.+)%.([^.]*)%.([^.]*)%.([^.]*)%.([^.]*)$")
	if not R or not Code(R) or not User(user) or not Time(exp) or (mode ~= "c" and mode ~= "a") or not Threshold(T) or not Sig(sig) then
		return nil
	end
	return { R = R, user = user, exp = tonumber(exp), mode = mode, T = T, sig = sig, signed = s:sub(1, #s - 87) }
end

-- A confirmer's certificate: { id, pub, tier, exp, name, sig, signed, text } or nil. The character
-- (Name-Realm) is what lies between the expiry and the last dot.
function Link.ParseCert(s)
	if type(s) ~= "string" or #s > Link.MAX_CERT then return nil end
	local id, pub, tier, exp, name, sig = s:match("^OLK2%.([^.]*)%.([^.]*)%.([^.]*)%.([^.]*)%.(.+)%.([^.]*)$")
	if not id or not KeyId(id) or not Pub(pub) or (tier ~= "c" and tier ~= "p") or not Time(exp) or not Link.ValidName(name) or not Sig(sig) then
		return nil
	end
	return { id = id, pub = pub, tier = tier, exp = tonumber(exp), name = name, sig = sig, signed = s:sub(1, #s - 87), text = s }
end

-- The id of a key the council authority certifies: the first 12 hex of SHA-256 of its 32 bytes.
local function KeyIdOf(pub) return Ed.ToHex(ns.Sign.SHA256(pub)):sub(1, 12) end
Link.KeyIdOf = KeyIdOf

-- Public keys a list names (32-byte strings): 64 hex digits that are a key a signature can be
-- checked with (Ed.ValidPublicKey), made once for the list as it is.
local function KeyList(list, cache)
	list = type(list) == "table" and list or {}
	local id = table.concat(list, ",")
	if cache.id ~= id then
		local out = {}
		for _, hex in ipairs(list) do
			local pk = type(hex) == "string" and #hex == 64 and Ed.FromHex(hex)
			if pk and Ed.ValidPublicKey(pk) then out[#out + 1] = pk end
		end
		cache.id, cache.keys = id, out
	end
	return cache.keys
end
local backendKeys, caKeys = {}, {}
-- The bot's public keys this version knows, and the council authority's.
function Link.BackendKeys() return KeyList(ns.LINK_BACKEND_KEYS, backendKeys) end
function Link.CAKeys() return KeyList(ns.LINK_CA_KEYS, caKeys) end
-- The bot is ready: this version knows one of its keys. Until then (Konig's review) no confirmer
-- key is made, typed, announced or used, and no certificate is asked for, signed or typed: a key
-- would only wait in the SavedVariables for the launch.
function Link.BotReady() return #Link.BackendKeys() > 0 end
-- The council authority's path runs: the author's switch on (ns.LINK_COUNCIL_AUTHORITY), the
-- authority's key known and the bot ready. Else councillors' keys, like everyone's, come from the
-- bot's keeper.
function Link.CouncilAuthority() return ns.LINK_COUNCIL_AUTHORITY == true and #Link.CAKeys() > 0 and Link.BotReady() end

-- Who signed a parsed code or certificate (its `signed` and `sig`): "bot" (one of the bot's
-- keys), "ca" (the council authority's: a certificate of tier c only, for a key whose id is its
-- hash, and only while its path runs: Link.CouncilAuthority), or false. Heavy: run inside Ed.Run.
local function SignedBy(t, certificate)
	local sig = type(t) == "table" and Ed.FromB64(t.sig)
	if not sig then return false end
	for _, pk in ipairs(Link.BackendKeys()) do
		if Ed.Verify(pk, t.signed, sig) then return "bot" end
	end
	if certificate and t.tier == "c" and Link.CouncilAuthority() then
		local pub = Ed.FromB64(t.pub)
		if pub and t.id == KeyIdOf(pub) then
			for _, pk in ipairs(Link.CAKeys()) do
				if Ed.Verify(pk, t.signed, sig) then return "ca" end
			end
		end
	end
	return false
end
local function BotSigned(t) return SignedBy(t, false) == "bot" end
local function CertSigned(t) return SignedBy(t, true) ~= false end
Link.VerifyToken, Link.VerifyCert, Link.CertSigner = BotSigned, CertSigned, function(c) return SignedBy(c, true) end

-- The tag that binds a link to its code and its requester: the first 16 hex of SHA-256 of the
-- code's signature (only in the command the player pasted), "~" and the requester's Name-Realm.
function Link.Tag(tokenSig, requester)
	return Ed.ToHex(ns.Sign.SHA256(tokenSig .. "~" .. requester)):sub(1, 16)
end

-- The text a confirmer signs for proof p of request b (UTF-8, as the names are).
function Link.Message(b, p)
	return table.concat({ "OLY4", b.requester, b.guild, p.gv, b.faction, b.nonce, b.R, b.tag, p.issued, p.keyId, p.confirmer }, "~")
end

-- The draw: a key's place for a code, the first 8 hex of SHA-256(R~keyId); it is drawn when
-- its place is below the code's threshold T (the same rule the bot applies with the same T).
function Link.Rank(R, keyId) return Ed.ToHex(ns.Sign.SHA256(R .. "~" .. keyId):sub(1, 4)) end
function Link.Drawn(place, T) return type(place) == "string" and type(T) == "string" and place < T end

-- The certificate a proof carries (its key's, for its confirmer): OLK2 rebuilt from its fields.
function Link.CertText(p)
	return ("OLK2.%s.%s.%s.%s.%s.%s"):format(p.keyId, p.pub, p.tier, p.certExp, p.confirmer, p.certSig)
end

local function ValidProof(p)
	return type(p) == "table" and Time(p.issued) and KeyId(p.keyId) and Link.ValidName(p.confirmer) and GV[p.gv] == true and Sig(p.sig)
		and Pub(p.pub) and (p.tier == "c" or p.tier == "p") and Time(p.certExp) and Sig(p.certSig) and #Link.CertText(p) <= Link.MAX_CERT
end
local function ValidHead(b)
	return type(b) == "table" and Link.ValidName(b.requester) and Link.ValidGuild(b.guild) and FACTIONS[b.faction] ~= nil
		and Nonce(b.nonce) and Code(b.R) and Tag(b.tag)
end
local PROOF_FIELDS = { "issued", "keyId", "confirmer", "gv", "sig", "pub", "tier", "certExp", "certSig" }

-- The link the page reads: the request and 1 to 4 proofs, each with its certificate.
function Link.Build(b, proofs)
	if not ValidHead(b) or type(proofs) ~= "table" or #proofs < 1 or #proofs > Link.MAX_PROOFS then return nil end
	local parts = {}
	for i, p in ipairs(proofs) do
		if not ValidProof(p) then return nil end
		local f = {}
		for j, k in ipairs(PROOF_FIELDS) do f[j] = p[k] end
		parts[i] = table.concat(f, ",")
	end
	local s = table.concat({ "OLB5", b.requester, b.guild, b.faction, b.nonce, b.R, b.tag, table.concat(parts, ";") }, "~")
	return #s <= Link.MAX_BUNDLE and s or nil
end

-- The link read back: { requester, guild, faction, nonce, R, tag, proofs = { ... } }, or nil.
function Link.Parse(s)
	if type(s) ~= "string" or #s > Link.MAX_BUNDLE then return nil end
	local requester, guild, faction, nonce, R, tag, list = s:match("^OLB5~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
	local b = { requester = requester, guild = guild, faction = faction, nonce = nonce, R = R, tag = tag, proofs = {} }
	if not requester or not ValidHead(b) then return nil end
	for part in (list .. ";"):gmatch("([^;]*);") do
		local p, n = {}, 0
		for v in (part .. ","):gmatch("([^,]*),") do
			n = n + 1
			if n > #PROOF_FIELDS then return nil end
			p[PROOF_FIELDS[n]] = v
		end
		if n ~= #PROOF_FIELDS or not ValidProof(p) or #b.proofs >= Link.MAX_PROOFS then return nil end
		b.proofs[#b.proofs + 1] = p
	end
	if #b.proofs == 0 then return nil end
	return b
end

-- JavaScript's encodeURIComponent: letters, digits and - _ . ! ~ * ' ( ) as they are, every
-- other byte (UTF-8 included) as %XX.
function Link.EncodeURI(s)
	return (s:gsub("[^A-Za-z0-9%-_%.!~%*'%(%)]", function(c) return ("%%%02X"):format(c:byte()) end))
end

function Link.URL(bundle) return tostring(ns.LINK_SITE) .. "#b=" .. Link.EncodeURI(bundle) end

-- "the bot's watcher", or "<name>'s watcher" (ns.LINK_WATCHER_OWNER).
function Link.WatcherLabel()
	local owner = ns.LINK_WATCHER_OWNER
	if type(owner) == "string" and owner ~= "" then return L.LINK_WATCHER_OF:format(owner) end
	return L.LINK_WATCHER_GENERIC
end

local function TierName(tier) return tier == "c" and L.LINK_TIER_C or L.LINK_TIER_P end
local function Hours(seconds) return math.max(1, math.ceil(seconds / 3600)) end
local function Days(seconds) return math.max(1, math.ceil(seconds / 86400)) end

---------------------------------------------------------------------------
-- Saved on the account (SylvanistasDB.discord): each character's request and proof (chars), each
-- character's confirmer key and its certificate (keys), the characters whose key was turned off
-- (nokey: a councillor's addon makes none until /syl discord key new), whom the account's keys
-- confirmed (given), and a watcher's inbox and switch.
---------------------------------------------------------------------------

local function Store()
	local db = ns.db
	if type(db.discord) ~= "table" then db.discord = {} end
	local d = db.discord
	for _, k in ipairs({ "chars", "given", "inbox", "watch", "keys", "nokey" }) do
		if type(d[k]) ~= "table" then d[k] = {} end
	end
	return d
end
Link.Store = Store

-- This character's record, without making the store for a player who never used Sylvanistas Link.
local function MyRecord()
	local d = ns.db and ns.db.discord
	local chars = type(d) == "table" and d.chars
	return type(chars) == "table" and chars[ns.me] or nil
end

-- This character's confirmer key: the saved record { id, seed, cert, auto } and its 32-byte
-- seed, or nil. A key is one character's: another character of the account has its own, or none.
function Link.Key()
	local d = ns.db and ns.db.discord
	local keys = type(d) == "table" and d.keys
	local k = type(keys) == "table" and keys[ns.me]
	if type(k) ~= "table" or not KeyId(k.id) or type(k.seed) ~= "string" or #k.seed ~= 43 then return nil end
	local seed = Ed.FromB64(k.seed)
	if not seed or #seed ~= 32 then return nil end
	return k, seed
end

-- Our certificate: parsed, for our key's id and this character, not expired; or nil. (That the
-- bot or the council authority signed it, for our key's public half, is checked in a job:
-- CheckOwnCert.)
local function MyCert(k)
	k = k or Link.Key()
	local c = k and Link.ParseCert(k.cert)
	if not c or c.id ~= k.id or c.name ~= ns.me or c.exp <= ServerTime() then return nil end
	return c
end

local function OwnCharacter(name)
	if ns.Treasury and ns.Treasury.IsOwnCharacter and not ns.Treasury.missing then return ns.Treasury.IsOwnCharacter(name) end
	local mine = ns.db and ns.db.myCharacters
	return type(mine) == "table" and type(name) == "string" and mine[name:lower()] == true
end

-- The watcher's inbox: [R][sender] = { bundle, from, t }. Entries in all, and one sender's.
local function InboxCount(inbox, from)
	local n, mine = 0, 0
	for _, slot in pairs(inbox or {}) do
		if type(slot) == "table" then
			for f in pairs(slot) do
				n = n + 1
				if f == from then mine = mine + 1 end
			end
		end
	end
	return n, mine
end

-- Until when a watcher keeps a link (server time): its code's expiry + GRACE, the expiry taken
-- as the latest proof's time + a code's life and the clocks' difference (a proof is signed within
-- its code's life, so that is never before the expiry). nil for a link without proofs.
function Link.KeepUntil(b)
	local latest
	for _, p in ipairs(type(b) == "table" and b.proofs or {}) do
		local t = tonumber(p.issued)
		if t and (not latest or t > latest) then latest = t end
	end
	return latest and latest + Link.CODE_LIFE + Link.CLOCK_SKEW + Link.GRACE or nil
end

-- Entries whose code can no longer be used go (anything malformed with them). An entry without
-- its time to go counts from when it came.
local function PruneInbox(inbox, now)
	local server = ServerTime()
	for R, slot in pairs(inbox) do
		if type(slot) ~= "table" then
			inbox[R] = nil
		else
			for from, e in pairs(slot) do
				local keep = type(e) == "table" and tonumber(e.keep)
				if type(e) ~= "table" or type(e.bundle) ~= "string" or (keep and server >= keep)
					or (not keep and now - (tonumber(e.t) or -math.huge) >= Link.GRACE + Link.CODE_LIFE) then
					slot[from] = nil
				end
			end
			if next(slot) == nil then inbox[R] = nil end
		end
	end
end

---------------------------------------------------------------------------
-- Who is online: confirmers (DV) and watchers (DW)
---------------------------------------------------------------------------

-- Our key's public half (32 bytes) from the cache, when it is for this key.
local function CachedPub(k)
	return pubCache and k and pubCache.id == k.id and pubCache.seed == k.seed and pubCache.pub or nil
end

-- Our certificate checked in a job: the bot (or the council authority) signed it, for our key's
-- public half. done(ok) after.
local function CheckOwnCert(done)
	local k, seed = Link.Key()
	local c = MyCert(k)
	if not c then return false end
	if ownCert and ownCert.cert == c.text and ownCert.seed == k.seed then
		if done then done(ownCert.ok) end
		return true
	end
	local what = c.text .. "~" .. k.seed
	if ownChecking == what then return true end
	ownChecking = what
	local cached = CachedPub(k)
	local queued = Ed.Run(function()
		local pub = cached or Ed.PublicKey(seed)
		return { pub = pub, ok = Ed.ToB64(pub) == c.pub and CertSigned(c) }
	end, function(ok, res)
		if ownChecking == what then ownChecking = nil end
		local k2 = Link.Key()
		if not ok or type(res) ~= "table" or not k2 or k2.seed ~= k.seed then return end
		pubCache = { id = k.id, seed = k.seed, pub = res.pub }
		ownCert = { cert = c.text, seed = k.seed, ok = res.ok and true or false }
		if not ownCert.ok and not toldCert then
			toldCert = true
			ns.Print(L.LINK_CERT_SAVED_BAD)
		end
		if done then done(ownCert.ok) end
	end)
	if not queued then ownChecking = nil end
	return queued
end

-- Our certificate, when it lets us confirm now: a councillor's (tier c) only while the signed
-- list names us.
local function UsableCert(k)
	local c = MyCert(k)
	if c and c.tier == "c" and not ns.IsHighCouncillor(ns.me) then return nil end
	return c
end

-- Every ANNOUNCE_EVERY with a key and a certificate the bot (or the council authority) signed
-- for it, once the bot is ready (never before). A councillor taken off the signed list stops:
-- DV~0 once, if it had announced.
function Link.Announce(force)
	local k = Link.Key()
	local c = k and Link.BotReady() and UsableCert(k)
	if not c then
		if announced then
			announced = nil
			ns.Comm.Send("CHANNEL", "DV~0", "linkannounce")
		end
		return false
	end
	local now = ns.Now()
	if not force and now - lastAnnounce < Link.ANNOUNCE_EVERY then return false end
	if not (ownCert and ownCert.cert == c.text and ownCert.seed == k.seed) then
		CheckOwnCert(function(ok) if ok then Link.Announce(true) end end)
		return false
	end
	if not ownCert.ok then return false end
	lastAnnounce, announced = now, c.text
	ns.Comm.Send("CHANNEL", "DV~1~" .. c.text, "linkannounce")
	return true
end

function Link.Watching()
	local d = ns.db and ns.db.discord
	return type(d) == "table" and type(d.watch) == "table" and d.watch[ns.me] == true and ns.IsHighCouncillor(ns.me)
end

function Link.AnnounceWatcher(force)
	if not Link.Watching() then return false end
	local now = ns.Now()
	if not force and now - lastWatch < Link.ANNOUNCE_EVERY then return false end
	lastWatch = now
	ns.Comm.Send("CHANNEL", "DW~1", "linkwatcher")
	return true
end

local function Prune(now)
	lastPrune = now
	local server = ServerTime()
	for name, a in pairs(announcers) do
		if now - a.t > Link.ANNOUNCE_FRESH or a.exp <= server then announcers[name], nAnnouncers = nil, nAnnouncers - 1 end
	end
	for name, t in pairs(watchers) do
		if now - t > Link.ANNOUNCE_FRESH then watchers[name] = nil end
	end
	for name, t in pairs(inboxTried) do
		if now - t >= Link.INBOX_GAP then inboxTried[name] = nil end
	end
	for name, t in pairs(certNewAt) do
		if now - t >= Link.CERT_NEW_GAP then certNewAt[name] = nil end
	end
	for name, t in pairs(ca.given) do
		if now - t >= Link.CA_GAP then ca.given[name] = nil end
	end
	ns.Codec.Gc(inAsm, now)
	local d = ns.db and ns.db.discord
	if type(d) == "table" and type(d.inbox) == "table" then PruneInbox(d.inbox, now) end
end

-- A "c" counts only from a councillor of the signed list whose certificate says c.
local function IsCouncillor(name, a) return a.tier == "c" and ns.IsHighCouncillor(name) end

-- A confirmer's certificate checked against the bot's keys, once (in a job, a few at a time);
-- the request steps on once it is.
local function CheckCert(a)
	local cert = a.cert
	if certs[cert] ~= nil or certJobs[cert] or nCertJobs >= Link.CERT_JOBS then return end
	local c = Link.ParseCert(cert)
	if not c then
		certs[cert] = false
		return
	end
	certJobs[cert], nCertJobs = true, nCertJobs + 1
	local queued = Ed.Run(function() return CertSigned(c) end, function(ok, valid)
		certJobs[cert], nCertJobs = nil, nCertJobs - 1
		if nCerts >= Link.CERT_CACHE then wipe(certs); nCerts = 0 end
		local good = ok and valid == true
		certs[cert], nCerts = good, nCerts + 1
		if not good then stats.badCerts = stats.badCerts + 1 end
		local r = req
		if r then
			if good then r.wantRound = true end
			Link.Step()
		end
	end)
	if not queued then certJobs[cert], nCertJobs = nil, nCertJobs - 1 end
end

-- Where a key stands in request r's draw (its place, computed once).
local function PlaceOf(r, id)
	local v = r.place[id]
	if not v then
		v = Link.Rank(r.rec.R, id)
		r.place[id] = v
	end
	return v
end

-- Every "p" confirmer online placed in request r's draw, in a job: a few thousand SHA-256s would
-- stall the click that accepted. Confirmers heard later are placed as they come (HandleAnnounce).
local function PlaceAll(r)
	if r.ranked or r.ranking then return end
	local ids, seen = {}, {}
	for _, a in pairs(announcers) do
		if a.tier == "p" and not seen[a.id] and not r.place[a.id] then
			seen[a.id] = true
			ids[#ids + 1] = a.id
		end
	end
	if #ids == 0 then
		r.ranked = true
		return
	end
	r.ranking = true
	local R = r.rec.R
	local queued = Ed.Run(function()
		local out = {}
		for _, id in ipairs(ids) do
			out[id] = Link.Rank(R, id)
			Ed.Pause()
		end
		return out
	end, function(ok, out)
		r.ranking = nil
		if req ~= r then return end
		if ok and type(out) == "table" then
			for id, v in pairs(out) do r.place[id] = r.place[id] or v end
			r.ranked = true
		end
		Link.Step()
	end)
	if not queued then r.ranking = nil end
end

-- Online confirmers request r may ask, with a certificate for them the bot (or the council
-- authority) signed and still valid: councillors (by name), or the players drawn for its code
-- (lowest place first). { name, id, pub, c, place, tier, certExp, certSig }, and how many more
-- wait for their certificate to be checked: they are checked (the lowest places first) and join
-- after.
local function Online(r, councillors, now)
	local out, unchecked = {}, {}
	local own, server, T = Link.Key(), ServerTime(), r.rec.T
	for name, a in pairs(announcers) do
		if now - a.t <= Link.ANNOUNCE_FRESH and a.exp > server and name ~= ns.me and not (own and own.id == a.id) then
			local c = IsCouncillor(name, a)
			local want
			if councillors then
				want = c
			else
				want = a.tier == "p" and r.ranked and Link.Drawn(PlaceOf(r, a.id), T)
			end
			if want then
				local e = { name = name, id = a.id, pub = a.pub, c = c, place = not c and r.place[a.id] or nil,
					tier = a.tier, certExp = tostring(a.exp), certSig = a.sig }
				local ok = certs[a.cert]
				if ok then
					out[#out + 1] = e
				elseif ok == nil then
					e.a = a
					unchecked[#unchecked + 1] = e
				end
			end
		end
	end
	local function Before(x, y)
		if x.place ~= y.place then return (x.place or "") < (y.place or "") end
		return x.name < y.name
	end
	table.sort(out, Before)
	table.sort(unchecked, Before)
	for _, e in ipairs(unchecked) do
		if nCertJobs >= Link.CERT_JOBS then break end
		CheckCert(e.a)
	end
	return out, #unchecked
end
Link.Online = Online

local function OnlineWatchers(now)
	local out = {}
	for name, t in pairs(watchers) do
		if now - t <= Link.ANNOUNCE_FRESH and name ~= ns.me and ns.IsHighCouncillor(name) then out[#out + 1] = { name = name, t = t } end
	end
	table.sort(out, function(x, y) return x.t > y.t end) -- the one heard last first
	return out
end

---------------------------------------------------------------------------
-- The requester
---------------------------------------------------------------------------

local SAY = { council = "LINK_ASKING_COUNCIL", draw = "LINK_DRAWING", waiting = "LINK_WAITING", waitingC = "LINK_WAITING_COUNCIL",
	claimed = "LINK_GUILD_CHECKING" }
local function Say(r, what)
	if r.told[what] then return end
	r.told[what] = true
	ns.Print(L[SAY[what]])
end

local function NewNonce(R)
	local seed = table.concat({ tostring(ns.me), R, tostring(time()), tostring(GetTime and GetTime() or 0), tostring(math.random()),
		tostring(math.random()), tostring(debugprofilestop and debugprofilestop() or 0), tostring({}) }, "~")
	return Ed.ToHex(ns.Sign.SHA256(seed)):sub(1, 16)
end

local function Head(rec)
	return { requester = ns.me, guild = rec.guild, faction = rec.faction, nonce = rec.nonce, R = rec.R, tag = rec.tag }
end

local function Strong(p) return p.gv == "r" or p.gv == "w" end
local function FreshP(p, now) return not p.c and now - (tonumber(p.got) or 0) <= Link.FRESH end

-- Proofs that showed the guild first; then councillors' in the order they came, players' by
-- their place in the draw.
local function Before(x, y)
	local sx, sy = Strong(x), Strong(y)
	if sx ~= sy then return sx end
	if x.c then
		local gx, gy = tonumber(x.got) or 0, tonumber(y.got) or 0
		if gx ~= gy then return gx < gy end
	elseif (x.place or "") ~= (y.place or "") then
		return (x.place or "") < (y.place or "")
	end
	return x.keyId < y.keyId
end

-- The proofs the link carries: councillors' (two at most) when there is one, with a player's
-- that showed the guild if theirs did not; else the players' fresh ones, one per key; four at most.
local function Chosen(rec, now)
	local C, P, ids = {}, {}, {}
	for _, p in pairs(rec.proofs) do
		if p.c and not ids[p.keyId] then
			ids[p.keyId] = true
			C[#C + 1] = p
		end
	end
	for _, p in pairs(rec.proofs) do
		if FreshP(p, now) and not ids[p.keyId] then
			ids[p.keyId] = true
			P[#P + 1] = p
		end
	end
	table.sort(C, Before)
	table.sort(P, Before)
	local list = {}
	for i = 1, math.min(#C, Link.COUNCIL_PROOFS) do list[#list + 1] = C[i] end
	if #list > 0 then
		local strong = false
		for _, p in ipairs(list) do strong = strong or Strong(p) end
		if not strong and P[1] and Strong(P[1]) then list[#list + 1] = P[1] end
	else
		for i = 1, math.min(#P, Link.MAX_PROOFS) do list[#list + 1] = P[i] end
	end
	return list
end

-- Councillors' and players' proofs in a list, and whether one showed the guild.
local function Counts(list)
	local c, p, strong = 0, 0, false
	for _, x in ipairs(list) do
		if x.c then c = c + 1 else p = p + 1 end
		strong = strong or Strong(x)
	end
	return c, p, strong
end

local function Enough(rec, list)
	local c, p = Counts(list)
	return c > 0 or (rec.mode == "a" and p >= Link.NEEDED)
end

-- A proof as the link carries it (and whether it is a councillor's): what a finished request
-- keeps while it waits for one that knows the guild.
local function Carried(p)
	local out = { c = p.c or nil }
	for _, k in ipairs(PROOF_FIELDS) do out[k] = p[k] end
	return out
end

-- A councillor online who can be asked now (and has not given a proof), or one whose turn runs.
local function CouncilLeft(r, now)
	if r.waitC and now < r.waitC then return true end
	for _, e in ipairs(Online(r, true, now)) do
		local a = r.asked[e.name]
		if not r.rec.proofs[e.name] and (not a or now - a.t >= Link.COUNCIL_AGAIN) then return true end
	end
	return false
end

-- A councillor to ask now: one without a proof, not asked within COUNCIL_AGAIN; or, while the
-- request waits for a proof that knows the guild, one whose proof only claimed it, asked again
-- CLAIMED_AGAIN after the last time (the /who it asked for may have seen the player since).
local function CouncilDue(r, e, now)
	local a, p = r.asked[e.name], r.rec.proofs[e.name]
	if r.verifying[e.name] then return false end
	if not p then return not a or now - a.t >= Link.COUNCIL_AGAIN end
	return r.rec.claimedAt ~= nil and not Strong(p) and (not a or now - a.t >= Link.CLAIMED_AGAIN)
end

local Candidates

local function Expire(r)
	local d = Store()
	if d.chars[ns.me] == r.rec then d.chars[ns.me] = nil end
	if req == r then req = nil end
	ns.Print(L.LINK_EXPIRED)
	ns.Log("discord link: request expired")
end

-- Finished: the link is made. With the guild only claimed it says so: the bot may want a
-- confirmer who saw it (LINK_GUILD_POLICY), and a new code while one is online does it.
local function Ready(r, now, list)
	local rec = r.rec
	local proofs = {}
	for i, p in ipairs(list) do proofs[i] = Carried(p) end
	local bundle = Link.Build(Head(rec), proofs)
	if not bundle then return end
	local c, _, strong = Counts(list)
	rec.state, rec.bundle, rec.readyAt, rec.n = "ready", bundle, now, #proofs
	rec.council, rec.verified = c > 0 or nil, strong or nil
	rec.proofs, rec.fallback, rec.claimedAt = nil, nil, nil
	req, delivery, waitWatcher = nil, nil, false
	wipe(sentTo)
	ns.Print(strong and L.LINK_READY or L.LINK_READY_CLAIMED)
	ns.Log("discord link: ready with %d proofs (%d councillors', guild %s)", #proofs, c, strong and "verified" or "claimed")
	Link.ShowWindow()
	Link.Deliver(now)
end

local function Ask(r, e, now)
	local rec = r.rec
	r.asked[e.name] = { id = e.id, pub = e.pub, c = e.c, place = e.place, t = now, tier = e.tier, certExp = e.certExp, certSig = e.certSig }
	ns.Comm.Whisper(e.name, ("DR~%s~%s~%s~%s~%s"):format(rec.nonce, rec.guild, rec.faction, rec.R, rec.tag), "linkask:" .. e.name, true)
end

-- Drawn players who can be asked now, lowest place first, one per key: online, certified, not a
-- councillor, without a fresh proof, not asked within ASK_AGAIN; and how many drawn ones wait for
-- their certificate to be checked.
Candidates = function(r, now)
	local out, ids = {}, {}
	if not r.ranked then return out, 0 end
	for _, p in pairs(r.rec.proofs) do
		if p.c or FreshP(p, now) then ids[p.keyId] = true end
	end
	local online, unchecked = Online(r, false, now)
	for _, e in ipairs(online) do
		local a = r.asked[e.name]
		if not ids[e.id] and not r.verifying[e.name] and not (a and now - a.t < Link.ASK_AGAIN) then
			ids[e.id] = true
			out[#out + 1] = e
		end
	end
	return out, unchecked
end

-- The draw, in rounds: five at once, the next five after DRAW_WAIT if still short, then the
-- request waits. A round starts at the request, at each login and when a confirmer who was not
-- asked comes online or is found certified (not sooner than ROUND_GAP after the last): players'
-- proofs older than FRESH are left out, so the ones carried were all made within minutes of each
-- other. Only players the code's threshold draws are asked, the lowest places first: the bot
-- takes a player's proof only from a key its own draw of this code picks (WORKER.md).
local function Draw(r, now)
	local round = r.round
	if round then
		if now < round.due then
			-- A batch short of five (few were online, or certified yet): the next ones join it.
			local room = math.min(Link.DRAW_FIRST - round.batch, Link.DRAW_MAX - round.asked)
			if room > 0 then
				local cands = Candidates(r, now)
				for i = 1, math.min(room, #cands) do
					Ask(r, cands[i], now)
					round.batch, round.asked = round.batch + 1, round.asked + 1
				end
			end
			return
		end
		if round.asked < Link.DRAW_MAX then
			local cands = Candidates(r, now)
			local n = math.min(Link.DRAW_MAX - round.asked, #cands)
			if n > 0 then
				for i = 1, n do Ask(r, cands[i], now) end
				round.asked, round.batch, round.due = round.asked + n, n, now + Link.DRAW_WAIT
				return
			end
		end
		r.round, r.roundEnded = nil, now
		if not Enough(r.rec, Chosen(r.rec, now)) then Say(r, "waiting") end
		return
	end
	if not r.wantRound or not r.ranked then return end
	if r.roundEnded and now - r.roundEnded < Link.ROUND_GAP then return end
	for name, p in pairs(r.rec.proofs) do
		if not p.c and not FreshP(p, now) then r.rec.proofs[name] = nil end
	end
	local cands = Candidates(r, now)
	if #cands == 0 then
		-- (Certificates still being checked: the round starts when one is found good.)
		if nCertJobs == 0 then
			r.wantRound = nil
			if not Enough(r.rec, Chosen(r.rec, now)) then Say(r, "waiting") end
		end
		return
	end
	r.wantRound = nil
	local n = math.min(Link.DRAW_FIRST, #cands)
	for i = 1, n do Ask(r, cands[i], now) end
	r.round = { asked = n, batch = n, due = now + Link.DRAW_WAIT }
	Say(r, "draw")
end

-- One step of the request: at the start, at each answer, when a confirmer comes online or is
-- found certified, and every few seconds (Link.Tick).
function Link.Step(now)
	local r = req
	if not r then return end
	now = now or ns.Now()
	local rec = r.rec
	if rec.state ~= "waiting" then return end
	local server = ServerTime()
	if rec.mode == "a" then PlaceAll(r) end
	local list = Chosen(rec, now)
	local enough = Enough(rec, list)
	local c, _, strong = Counts(list)
	if enough and strong then
		-- Enough, and the guild shown: ready, but for a second councillor online, asked for
		-- MORE_WAIT at most.
		r.enoughAt = r.enoughAt or now
		if not (c == 1 and now - r.enoughAt < Link.MORE_WAIT and CouncilLeft(r, now)) then return Ready(r, now, list) end
	else
		r.enoughAt = nil
		if enough then
			-- Enough for the bot, the guild only claimed: kept (a player's proof stops counting with
			-- the others after FRESH), and open CLAIMED_WAIT for a proof that knows the guild.
			rec.claimedAt = rec.claimedAt or now
			rec.fallback = {}
			for i, p in ipairs(list) do rec.fallback[i] = Carried(p) end
			Say(r, "claimed")
		end
	end
	if rec.claimedAt and type(rec.fallback) == "table" then
		-- The wait ends, or the code does (the bot takes proofs signed before its expiry).
		if now - rec.claimedAt >= Link.CLAIMED_WAIT or server >= rec.exp - Link.CLOCK_SKEW then
			return Ready(r, now, enough and list or rec.fallback)
		end
	elseif server >= rec.exp then
		return Expire(r)
	end
	-- High Councillors first, one at a time (the first proof does it; a second one is asked for,
	-- and one that only claimed the guild is asked again while the request waits for one that
	-- knows it).
	if r.waitC and now < r.waitC then return end
	for _, e in ipairs(Online(r, true, now)) do
		if CouncilDue(r, e, now) then
			Ask(r, e, now)
			r.waitC = now + Link.COUNCIL_WAIT
			return Say(r, "council")
		end
	end
	if rec.mode ~= "a" then
		if #list == 0 and nCertJobs == 0 then Say(r, "waitingC") end
		return
	end
	-- Waiting for a proof that knows the guild: the draw goes on, a round every ROUND_GAP.
	if rec.claimedAt and not r.round and (not r.roundEnded or now - r.roundEnded >= Link.ROUND_GAP) then r.wantRound = true end
	Draw(r, now)
end

local function Runtime(rec)
	return { rec = rec, asked = {}, told = {}, wantRound = true, place = {}, verifying = {}, ranked = rec.mode ~= "a" }
end

-- After the player's Accept: a new request for this character (an older one is replaced). The
-- code's signature makes the tag here and is kept nowhere.
function Link.Start(t)
	if type(t) ~= "table" or not Code(t.R) or not User(t.user) or (t.mode ~= "c" and t.mode ~= "a") or not Threshold(t.T) or not Sig(t.sig) then
		return false
	end
	if (tonumber(t.exp) or 0) <= ServerTime() then return ns.Print(L.LINK_CODE_EXPIRED) end
	if not ns.IsMember() then return ns.Print(L.LINK_NOT_MEMBER) end
	local guild = GetGuildInfo("player")
	local faction = ns.faction
	if not Link.ValidName(ns.me) or not Link.ValidGuild(guild) or not FACTIONS[faction] then return ns.Print(L.LINK_CANT) end
	local now = ns.Now()
	local rec = { R = t.R, user = t.user, exp = t.exp, mode = t.mode, T = t.T, tag = Link.Tag(t.sig, ns.me), nonce = NewNonce(t.R),
		guild = guild, faction = faction, started = now, state = "waiting", proofs = {} }
	Store().chars[ns.me] = rec
	delivery, waitWatcher = nil, false
	Link.HideWindow()
	req = Runtime(rec)
	ns.Print(L.LINK_STARTED)
	ns.Log("discord link: request started (mode %s)", t.mode)
	Link.Step(now)
	return true
end

-- A confirmer online (DV): its certificate read (checked only when it is asked), and only from
-- the character it names; a request waiting places it in its draw and asks it when it can. A
-- character's new certificate (one not checked yet) is taken once a minute at most: a flood of
-- them from one character can't make a waiting requester check more.
function Link.HandleAnnounce(dist, sender, text)
	if dist ~= "CHANNEL" or type(text) ~= "string" then return end
	local name = ns.FullName(sender)
	if name == ns.me then return end
	local now = ns.Now()
	if text == "DV~0" then
		if announcers[name] then announcers[name], nAnnouncers = nil, nAnnouncers - 1 end
		return
	end
	local cert = text:match("^DV~1~(OLK2%.[^~]+)$")
	local c = cert and Link.ParseCert(cert)
	if not c or c.name ~= name or c.exp <= ServerTime() then return end
	local a = announcers[name]
	if not (a and a.cert == cert) and certs[cert] == nil then
		if certNewAt[name] and now - certNewAt[name] < Link.CERT_NEW_GAP then return end
		certNewAt[name] = now
	end
	if not a then
		if nAnnouncers >= Link.MAX_ANNOUNCERS then Prune(now) end
		if nAnnouncers >= Link.MAX_ANNOUNCERS then return end
		nAnnouncers = nAnnouncers + 1
	end
	local known = a and a.cert == cert and now - a.t <= Link.ANNOUNCE_FRESH
	announcers[name] = { id = c.id, tier = c.tier, pub = c.pub, exp = c.exp, sig = c.sig, cert = cert, t = now }
	local r = req
	if r and r.rec.state == "waiting" and not known then
		if r.rec.mode == "a" and c.tier == "p" then PlaceOf(r, c.id) end
		local asked = r.asked[name]
		if not asked or now - asked.t >= Link.ASK_AGAIN then r.wantRound = true end
		Link.Step(now)
	end
end

-- A proof (DA): only from a confirmer we asked for this request, with the key we asked it for;
-- the confirmer is the name the server stamped (the one its certificate names), and it was
-- signed within the code's life (from its issue, CODE_LIFE before its expiry, less the clocks'
-- difference) and not ahead of our clock, as the bot checks it. Counted only once its signature
-- checks with the certified key (in a job). It carries that certificate in the link.
function Link.HandleAnswer(dist, sender, text)
	local r = req
	if dist ~= "WHISPER" or not r or type(text) ~= "string" or r.rec.state ~= "waiting" then return end
	local name = ns.FullName(sender)
	local a = r.asked[name]
	if not a or not Link.ValidName(name) or r.verifying[name] then return end
	local issued, keyId, gv, sig = text:match("^DA~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
	if not Time(issued) or keyId ~= a.id or not GV[gv] or not Sig(sig) then return end
	local rec = r.rec
	local t = tonumber(issued)
	if t > rec.exp or t < rec.exp - Link.CODE_LIFE - Link.CLOCK_SKEW or t > ServerTime() + Link.CLOCK_SKEW then return end
	local old = rec.proofs[name]
	if old and old.sig == sig then return end
	local p = { issued = issued, keyId = keyId, confirmer = name, gv = gv, sig = sig, pub = a.pub, tier = a.tier, certExp = a.certExp,
		certSig = a.certSig, c = a.c or nil, place = a.place, got = ns.Now() }
	local pk, raw, msg = Ed.FromB64(a.pub), Ed.FromB64(sig), Link.Message(Head(rec), p)
	r.verifying[name] = true
	local queued = Ed.Run(function() return Ed.Verify(pk, msg, raw) end, function(ok, valid)
		r.verifying[name] = nil
		if req ~= r or rec.state ~= "waiting" then return end
		if not ok or valid ~= true then
			stats.badProofs = stats.badProofs + 1
			ns.Log("discord link: a proof that does not check was left out")
		else
			rec.proofs[name] = p
			if p.c then r.waitC = nil end -- that councillor's turn is over: the next one now
		end
		Link.Step()
	end)
	if not queued then r.verifying[name] = nil end
end

---------------------------------------------------------------------------
-- The finished proof and the watchers
---------------------------------------------------------------------------

-- A finished proof still goes to a watcher: until its code's expiry + DELIVER_UNTIL, so the
-- keeper has KEEPER_TIME left to upload it before the bot stops taking it (exp + GRACE).
local function Deliverable(rec)
	return type(rec) == "table" and rec.state == "ready" and type(rec.bundle) == "string"
		and ServerTime() < (tonumber(rec.exp) or 0) + Link.DELIVER_UNTIL
end

-- Our proof (as ourselves: a watcher keeps only the requester's own) to a watcher.
local function SendBundle(to, bundle)
	local msg = "DB~" .. bundle
	if #msg <= 255 then
		ns.Comm.Whisper(to, msg, "linkbundle", true)
		return
	end
	bundleId = (bundleId + 1) % 1000
	for _, piece in ipairs(ns.Codec.Chunk(bundle, "L" .. bundleId)) do ns.Comm.Whisper(to, "DB~" .. piece, nil, true) end
end

-- A watcher we are one of ourselves takes it at once.
local Keep

-- The proof of this character to an online watcher, until one says it kept it. An unanswered
-- one (the watcher left, or its inbox was full) waits until a watcher is heard again.
function Link.Deliver(now)
	now = now or ns.Now()
	local rec = MyRecord()
	if not Deliverable(rec) then return false end
	if Link.Watching() then
		-- (Our own proofs were each checked when they came.)
		if Keep(rec.bundle, ns.me, now, Link.KeepUntil(Link.Parse(rec.bundle))) then
			rec.state, rec.deliveredAt = "delivered", now
			ns.Print(L.LINK_DELIVERED:format(Link.WatcherLabel()))
		end
		return true
	end
	if delivery then
		if now < delivery.due then return false end
		delivery, waitWatcher = nil, true
	end
	if waitWatcher then return false end
	local w = OnlineWatchers(now)[1]
	if not w then return false end
	SendBundle(w.name, rec.bundle)
	sentTo[w.name] = true
	delivery = { to = w.name, due = now + Link.ACK_WAIT }
	ns.Log("discord link: proof sent to a watcher")
	return true
end

-- A watcher online (DW): honoured from a High Councillor only.
function Link.HandleWatcher(dist, sender, text)
	if dist ~= "CHANNEL" or not ns.IsHighCouncillor(sender) then return end
	local name, now = ns.FullName(sender), ns.Now()
	if text == "DW~0" then
		watchers[name] = nil
		return
	end
	if text ~= "DW~1" then return end
	watchers[name] = now
	waitWatcher = false
	Link.Deliver(now)
end

-- The watcher kept our proof (DK).
function Link.HandleAck(dist, sender, text)
	if dist ~= "WHISPER" then return end
	local name, now = ns.FullName(sender), ns.Now()
	local rec = MyRecord()
	if not sentTo[name] or type(rec) ~= "table" or rec.state ~= "ready" or text ~= "DK~" .. tostring(rec.R) then return end
	rec.state, rec.deliveredAt = "delivered", now
	delivery = nil
	ns.Print(L.LINK_DELIVERED:format(Link.WatcherLabel()))
	ns.Log("discord link: proof kept by a watcher")
end

-- A watcher keeps a proof: INBOX_PER_SENDER per sender (one: a character's latest link, since its
-- addon holds one request at a time; a newer one, for this code or another, replaces its older
-- one) and INBOX_MAX in all. No cap per code: R is public (a stream's QR code shows it), any
-- character can get a councillor's real proof for itself with someone's R and a made-up tag, and
-- only the bot can check the tag, so a cap per code would let three such characters lock the real
-- requester out. A proof kept was acknowledged (DK), so nothing of another sender's is dropped to
-- make room: past INBOX_MAX a new sender is refused, without DK. An entry goes once its code can't
-- be used any more (keep: KeepUntil).
Keep = function(bundle, from, now, keep)
	local b = Link.Parse(bundle)
	if not b or b.requester ~= from or not keep then return false end
	local inbox = Store().inbox
	local slot = inbox[b.R]
	local e = type(slot) == "table" and slot[from]
	if type(e) == "table" then
		e.bundle, e.from, e.t, e.keep = bundle, from, now, keep
		stats.kept = stats.kept + 1
		return b
	end
	-- The sender's own entries for other codes (older links of its own).
	local mine = {}
	for R, s in pairs(inbox) do
		if type(s) == "table" and s[from] ~= nil then mine[#mine + 1] = R end
	end
	if #mine < Link.INBOX_PER_SENDER and InboxCount(inbox) >= Link.INBOX_MAX then
		PruneInbox(inbox, now)
		if InboxCount(inbox) >= Link.INBOX_MAX then return false end
	end
	local function Age(R)
		local x = type(inbox[R]) == "table" and inbox[R][from]
		return type(x) == "table" and tonumber(x.t) or -math.huge
	end
	while #mine >= Link.INBOX_PER_SENDER do
		local oldest = 1
		for i = 2, #mine do
			if Age(mine[i]) < Age(mine[oldest]) then oldest = i end
		end
		local R = table.remove(mine, oldest)
		if type(inbox[R]) == "table" then
			inbox[R][from] = nil
			if next(inbox[R]) == nil then inbox[R] = nil end
		end
	end
	slot = inbox[b.R]
	if type(slot) ~= "table" then
		slot = {}
		inbox[b.R] = slot
	end
	slot[from] = { bundle = bundle, from = from, t = now, keep = keep }
	stats.kept = stats.kept + 1
	return b
end

-- What a watcher checks before a link takes a place in its inbox (heavy: in a job). Every proof:
-- its certificate names its confirmer (the link carries it so), the bot or the council authority
-- signed it, it was valid when the proof was signed, and the proof's signature checks with it.
-- And together they are enough for the bot: a High Councillor's (the signed list), or three
-- players' from three keys. Junk never takes a place in the inbox.
local function CheckBundle(b)
	local c, players, keys = 0, 0, {}
	for _, p in ipairs(b.proofs) do
		local cert = Link.ParseCert(Link.CertText(p))
		if not cert or tonumber(p.issued) >= cert.exp then return false end
		local good = certs[cert.text]
		if good == nil then
			good = CertSigned(cert)
			if nCerts >= Link.CERT_CACHE then wipe(certs); nCerts = 0 end
			certs[cert.text], nCerts = good, nCerts + 1
		end
		if not good then return false end
		if not Ed.Verify(Ed.FromB64(p.pub), Link.Message(b, p), Ed.FromB64(p.sig)) then return false end
		if p.tier == "c" then
			if ns.IsHighCouncillor(p.confirmer) then c = c + 1 end
		elseif not keys[p.keyId] then
			keys[p.keyId], players = true, players + 1
		end
	end
	return c > 0 or players >= Link.NEEDED
end

local function Ack(from, R) ns.Comm.Whisper(from, "DK~" .. R, "linkack:" .. from, true) end

-- A proof for our inbox (DB), whole or in pieces: only from the requester it names, its proofs
-- checked first (CheckBundle), one link per requester a minute and INBOX_CHECKS at once; told
-- back with DK once kept. The same link again (our word was lost) is told again at once.
function Link.HandleBundle(dist, sender, text)
	if dist ~= "WHISPER" or type(text) ~= "string" or not Link.Watching() then return end
	local from, now = ns.FullName(sender), ns.Now()
	local payload = text:sub(4)
	local full = payload
	if payload:sub(1, 5) ~= "OLB5~" then full = ns.Codec.Feed(inAsm, from, payload, now) end
	if not full then return end
	local b = Link.Parse(full)
	if not b or b.requester ~= from then return end
	local slot = Store().inbox[b.R]
	local e = type(slot) == "table" and slot[from]
	if type(e) == "table" and e.bundle == full then return Ack(from, b.R) end
	if checking[from] or nChecking >= Link.INBOX_CHECKS or (inboxTried[from] and now - inboxTried[from] < Link.INBOX_GAP) then return end
	-- Proofs from the future, or a link whose code can't be used any more: not even checked.
	local server, keep = ServerTime(), Link.KeepUntil(b)
	for _, p in ipairs(b.proofs) do
		if tonumber(p.issued) > server + Link.CLOCK_SKEW then return end
	end
	if not keep or server >= keep then return end
	inboxTried[from] = now
	checking[from], nChecking = true, nChecking + 1
	local queued = Ed.Run(function() return CheckBundle(b) end, function(ok, good)
		checking[from], nChecking = nil, nChecking - 1
		if not ok or good ~= true then
			stats.badBundles = stats.badBundles + 1
			ns.Log("discord link: a link whose proofs don't check: refused")
			return
		end
		if not Link.Watching() then return end
		if not Keep(full, from, ns.Now(), keep) then
			ns.Log("discord link: the inbox is full for a proof: refused")
			return
		end
		ns.Log("discord link: proof kept in the inbox")
		Ack(from, b.R)
	end)
	if not queued then
		checking[from], nChecking, inboxTried[from] = nil, nChecking - 1, nil
	end
end

-- /syl discord watcher on | off (High Councillors).
function Link.SetWatcher(on)
	if not ns.IsHighCouncillor(ns.me) then return ns.Print(L.LINK_WATCHER_ONLY) end
	local d = Store()
	d.watch[ns.me] = on and true or nil
	if on then
		ns.Print(L.LINK_WATCHER_ON:format((InboxCount(d.inbox))))
		Link.AnnounceWatcher(true)
	else
		ns.Print(L.LINK_WATCHER_OFF)
		ns.Comm.Send("CHANNEL", "DW~0", "linkwatcher")
	end
end

---------------------------------------------------------------------------
-- The confirmer
---------------------------------------------------------------------------

-- Our key's limits: one proof per requesting character a minute and five a day (kept on the
-- account: every key of its characters together), thirty a minute in all.
local function Allowed(requester, now)
	while recent[1] and now - recent[1] >= 60 do table.remove(recent, 1) end
	if #recent >= Link.GIVE_MINUTE then return false end
	local times = Store().given[requester]
	if type(times) ~= "table" then return true end
	for i = #times, 1, -1 do
		if type(times[i]) ~= "number" or now - times[i] >= 86400 then table.remove(times, i) end
	end
	if #times >= Link.GIVE_DAY then return false end
	return not times[#times] or now - times[#times] >= Link.GIVE_GAP
end

local function Given(requester, now)
	recent[#recent + 1] = now
	local given = Store().given
	local times = type(given[requester]) == "table" and given[requester] or {}
	times[#times + 1] = now
	given[requester] = times
end

-- How we know the requester's guild, signed with the proof: "r" it is our own guild, byte for
-- byte, and our roster (read) lists them; "w" our /who saw them in exactly that guild within
-- WHO_FRESH; "c" only claimed. nil when what we know says otherwise (they claim our guild and our
-- roster doesn't list them, or a recent /who shows them in another guild): nothing is signed.
function Link.GuildFlag(requester, guild)
	local own = GetGuildInfo("player")
	local roster = ns.Roster
	local read = type(own) == "string" and type(roster) == "table" and roster.guild == own and type(roster.byName) == "table"
		and next(roster.byName) ~= nil
	if read and own:lower() == guild:lower() then
		if roster.RankOf(requester) == nil then return nil end
		if own == guild then return "r" end
	end
	local seen, age
	if ns.Who and type(ns.Who.SeenGuild) == "function" then seen, age = ns.Who.SeenGuild(requester) end
	if type(seen) == "string" and type(age) == "number" and age <= Link.WHO_FRESH then
		if seen == guild then return "w" end
		return nil
	end
	return "c"
end

-- Our key's public half (32 bytes) to done(pub), made once a session (in a job).
function Link.PublicKey(done)
	local k, seed = Link.Key()
	if not k then return false end
	local cached = CachedPub(k)
	if cached then
		done(cached)
		return true
	end
	return Ed.Run(function() return Ed.PublicKey(seed) end, function(ok, pub)
		if not ok then return end
		pubCache = { id = k.id, seed = k.seed, pub = pub }
		done(pub)
	end)
end

-- A request (DR): signed for a player of a Sylvanistas guild of our faction who asks it
-- themselves, within the limits, never one of our own account's characters, and only with a
-- certificate for our key and this character (without one no requester asks us; a councillor's
-- only while the signed list names us). Anything else is ignored without a word. A High
-- Councillor who could only sign the guild as claimed asks for the player's /who (sent quietly
-- with a later click in the Sylvanistas window, never with the gamepad UI, Who.lua): the player's
-- addon asks again while it waits for a proof that knows the guild, and then the proof says "w".
function Link.HandleRequest(dist, sender, text)
	if dist ~= "WHISPER" or type(text) ~= "string" or not Link.BotReady() then return end
	local key, seed = Link.Key()
	if not key or not UsableCert(key) then return end
	local requester, now = ns.FullName(sender), ns.Now()
	if requester == ns.me or OwnCharacter(requester) or not Link.ValidName(requester) or not Link.ValidName(ns.me) then return end
	local nonce, guild, faction, R, tag = text:match("^DR~([^~]*)~([^~]*)~([^~]*)~([^~]*)~([^~]*)$")
	if not Nonce(nonce) or not Link.ValidGuild(guild) or not FACTIONS[faction] or not Code(R) or not Tag(tag) then return end
	if not ns.IsFederation(guild) or faction ~= ns.faction then return end
	local gv = Link.GuildFlag(requester, guild)
	if not gv then return end
	if not Allowed(requester, now) then
		stats.refused = stats.refused + 1
		return
	end
	if Ed.Busy() >= Ed.MAX_JOBS then return end -- (no room to sign now: not counted, they ask again)
	Given(requester, now)
	local b = { requester = requester, guild = guild, faction = faction, nonce = nonce, R = R, tag = tag }
	local p = { issued = tostring(ServerTime()), keyId = key.id, confirmer = ns.me, gv = gv }
	local msg = Link.Message(b, p)
	local cached = CachedPub(key)
	Ed.Run(function()
		local pub = cached or Ed.PublicKey(seed)
		return { sig = Ed.Sign(seed, msg, pub), pub = pub }
	end, function(ok, res)
		if not ok or type(res) ~= "table" then return end
		if not cached then pubCache = { id = key.id, seed = key.seed, pub = res.pub } end
		stats.confirmed = stats.confirmed + 1
		ns.Comm.Whisper(requester, ("DA~%s~%s~%s~%s"):format(p.issued, p.keyId, gv, Ed.ToB64(res.sig)), "linkanswer:" .. requester, true)
		ns.Log("discord link: confirmed a request (guild %s)", gv)
	end)
	if gv == "c" and ns.IsHighCouncillor(ns.me) and ns.Who and type(ns.Who.WantName) == "function" then ns.Who.WantName(requester) end
end

-- /syl discord key [<id> <key> | new | off], /syl discord cert [<certificate>]. Nothing typed is
-- ever repeated back, and the key itself never shown: its id and public half only.
function Link.ShowKey()
	local k = Link.Key()
	if not k then return ns.Print(L.LINK_KEY_NONE) end
	Link.PublicKey(function(pub) ns.Print(L.LINK_KEY_SHOW:format(k.id, Ed.ToHex(pub))) end)
end

-- This character's key gone (and its certificate): said on the channel if we had announced it.
local function DropKey()
	local d = Store()
	local had = Link.Key()
	d.keys[ns.me], pubCache, ownCert, ownChecking, toldCert = nil, nil, nil, nil, false
	making, auto = nil, {}
	if had or announced then
		announced = nil
		ns.Comm.Send("CHANNEL", "DV~0", "linkannounce")
	end
	return had
end

-- A key dropped in game whose certificate still runs keeps counting at the bot (whose checks
-- don't ask this addon) until its keeper revokes it: its id is said, to send them.
local function SayOldKey(k)
	local c = type(k) == "table" and Link.ParseCert(k.cert)
	if c and c.exp > ServerTime() then ns.Print(L.LINK_KEY_OLD:format(k.id)) end
end

function Link.SetKey(args)
	args = tostring(args or ""):match("^%s*(.-)%s*$")
	local d = Store()
	if args == "" then return Link.ShowKey() end
	local verb = args:lower()
	if verb == "off" then
		local had = DropKey()
		d.nokey[ns.me] = true -- (a councillor's addon makes no new key by itself)
		ns.Print(Link.CouncilAuthority() and ns.IsHighCouncillor(ns.me) and L.LINK_KEY_OFF_COUNCIL or L.LINK_KEY_OFF)
		return SayOldKey(had)
	end
	if verb == "new" then
		-- A councillor's new key (a lost or leaked one, or one a year old): made here, and the
		-- author's client certifies it the next time it is heard; only while that path runs. Off
		-- (the default), a new key is one the bot's keeper makes, as everyone's.
		if not Link.BotReady() then return ns.Print(L.LINK_NOT_OPEN) end
		if not Link.CouncilAuthority() then return ns.Print(L.LINK_KEY_FROM_KEEPER) end
		if not ns.IsHighCouncillor(ns.me) then return ns.Print(L.LINK_KEY_NEW_ONLY) end
		local had = DropKey()
		d.nokey[ns.me] = nil
		Link.MakeCouncilKey()
		ns.Print(L.LINK_KEY_NEW)
		return SayOldKey(had)
	end
	local id, seed = args:match("^(%S+)%s+(%S+)$")
	id = id and id:lower()
	if not KeyId(id) or not seed or #seed ~= 43 or not Ed.FromB64(seed) then return ns.Print(L.LINK_KEY_BAD) end
	-- (Not kept before the bot is ready: it would wait, in plain text, for a launch.)
	if not Link.BotReady() then return ns.Print(L.LINK_NOT_OPEN) end
	local old = d.keys[ns.me]
	local cert = type(old) == "table" and old.cert or nil
	local oldCert = Link.ParseCert(cert)
	making, auto = nil, {}
	d.nokey[ns.me] = nil
	d.keys[ns.me], pubCache, ownCert, toldCert = { id = id, seed = seed }, nil, nil, false
	ns.Print(L.LINK_KEY_SET:format(id))
	if cert ~= nil and oldCert and oldCert.id == id then
		d.keys[ns.me].cert = cert
	elseif cert ~= nil then
		ns.Print(L.LINK_CERT_REMOVED)
	end
	Link.ShowKey()
	if not MyCert() then ns.Print(L.LINK_CERT_NEEDED) end
	lastAnnounce = -math.huge
	Link.Announce(true)
end

function Link.ShowCert()
	local k = Link.Key()
	local c = k and MyCert(k)
	if not c then return ns.Print(L.LINK_CERT_NONE) end
	ns.Print(L.LINK_CERT_SHOW:format(c.id, TierName(c.tier), Days(c.exp - ServerTime())))
end

-- A certificate for our key: checked (the bot's signature or, for a councillor's, the council
-- authority's; our key's id and public half; this character; the expiry) before it is kept; then
-- our addon says it is online.
function Link.SetCert(args)
	args = tostring(args or ""):match("^%s*(.-)%s*$")
	if args == "" then return Link.ShowCert() end
	local k, seed = Link.Key()
	if not k then return ns.Print(L.LINK_CERT_NO_KEY) end
	local c = Link.ParseCert(args)
	if not c then return ns.Print(L.LINK_CERT_USAGE) end
	if c.id ~= k.id then return ns.Print(L.LINK_CERT_OTHER:format(c.id, k.id)) end
	if c.name ~= ns.me then return ns.Print(L.LINK_CERT_OTHER_CHAR:format(c.name, ns.me)) end
	if c.exp <= ServerTime() then return ns.Print(L.LINK_CERT_EXPIRED) end
	if not Link.BotReady() then return ns.Print(L.LINK_NOT_OPEN) end
	ns.Print(L.LINK_CERT_CHECKING)
	local cached = CachedPub(k)
	local queued = Ed.Run(function()
		local pub = cached or Ed.PublicKey(seed)
		return { pub = pub, mine = Ed.ToB64(pub) == c.pub, signed = CertSigned(c) }
	end, function(ok, res)
		local k2 = Link.Key()
		if not k2 or k2.seed ~= k.seed then return end -- the key changed meanwhile
		if not ok or type(res) ~= "table" then return ns.Print(L.LINK_CERT_BAD) end
		pubCache = { id = k.id, seed = k.seed, pub = res.pub }
		if not res.mine then return ns.Print(L.LINK_CERT_NOT_MINE) end
		if not res.signed then return ns.Print(L.LINK_CERT_BAD) end
		k2.cert = c.text
		ownCert, toldCert = { cert = c.text, seed = k.seed, ok = true }, false
		ns.Print(L.LINK_CERT_SET:format(c.id, TierName(c.tier), Days(c.exp - ServerTime())))
		lastAnnounce = -math.huge
		Link.Announce(true)
	end)
	if not queued then ns.Print(L.LINK_BUSY) end
end

---------------------------------------------------------------------------
-- High Councillors' keys, certified by the author's client (the council authority)
--
-- Off by default (ns.LINK_COUNCIL_AUTHORITY, Konig's review): councillors then type the key and
-- certificate the bot's keeper made them, as every confirmer does, and none of this runs. Only
-- with the author's switch on, and once the bot is ready (Link.CouncilAuthority):
-- a councillor pastes nothing: its addon makes a key of its own in the game, the first time it
-- finds the signed list naming its character, and asks the author's client for a certificate
-- (DC, a whisper, once it hears the author: any message of his). The author's client, holding the
-- council authority's seed (dist/LinkCA.lua, on his computer only), certifies a councillor of the
-- signed list of its realm group (DE): tier c, the character's name, a year. The councillor's
-- private key never leaves its game, and the authority's never leaves the author's.
---------------------------------------------------------------------------

-- One sample of the entropy pool a councillor's key is made from, taken once a frame for
-- ENTROPY_FRAMES frames: debugprofilestop() (a millisecond clock with fractions: the frame's
-- timing), GetTimePreciseSec() where the client has it, GetTime(), GetServerTime(), time(),
-- math.random() twice, the addresses of two new tables (tostring({})), UnitGUID("player") and
-- GetCursorPosition(). SHA-512 of the whole pool, cut to 32 bytes, is the key's seed.
-- Its limits, honestly: WoW's Lua has no cryptographic random source, and none of these is one.
-- The GUID, the times to the second and the cursor are known to, or guessable by, someone who
-- watches; math.random is the game's generator, whose state is not secret by design; the table
-- addresses depend on the heap. What an attacker can't know is the sub-millisecond readings of
-- debugprofilestop and GetTimePreciseSec over eight frames on this computer (the frame-to-frame
-- jitter), and the exact second the key was made: tens of bits, not 256. That is why this path is
-- off by default (Konig's review): a key made so is kept in plain text in the SavedVariables, its
-- public half goes on the channel every 5 minutes, and its certificate lasts a year. Turned on, it
-- makes a key that only confirms Discord links, that the bot's keeper can revoke at once (the
-- Worker's revocation lists, by key or by character) and that /syl discord key new replaces in
-- game (it prints the old key's id: the keeper revokes that one at the bot). By default every
-- councillor's key is made from a real random source by the bot's keeper (scripts/link-keys.py
-- confirmer, on a computer) and typed with /syl discord key <id> <key>.
function Link.EntropySample()
	local parts = {}
	local function Add(fn, ...)
		if type(fn) ~= "function" then return end
		local ok, a, b = pcall(fn, ...)
		if ok then parts[#parts + 1] = tostring(a) .. "," .. tostring(b) end
	end
	Add(_G.debugprofilestop)
	Add(_G.GetTimePreciseSec)
	Add(_G.GetTime)
	Add(_G.GetServerTime)
	Add(_G.time)
	parts[#parts + 1] = tostring(math.random()) .. "," .. tostring(math.random())
	parts[#parts + 1] = tostring({}) .. "," .. tostring({})
	Add(_G.UnitGUID, "player")
	Add(_G.GetCursorPosition)
	Add(_G.debugprofilestop)
	return table.concat(parts, "~")
end

-- The next frame (a sample of the pool a frame). Tests run the frames themselves.
Link.nextFrame = function(fn) C_Timer.After(0, fn) end

local function WantAuthor()
	if ns.Comm then ns.Comm.senderHook = Link.HeardFrom end
end

-- A new key for this councillor: the pool stirred over ENTROPY_FRAMES frames, then its seed and
-- public half in a job; kept for this character (auto: its certificate comes by itself).
function Link.MakeCouncilKey()
	if making or not Link.CouncilAuthority() then return false end
	local m = { samples = {}, me = ns.me }
	making = m
	local function Frame()
		if making ~= m then return end
		if ns.me ~= m.me then making = nil return end
		m.samples[#m.samples + 1] = Link.EntropySample()
		if #m.samples < Link.ENTROPY_FRAMES then return Link.nextFrame(Frame) end
		local pool = table.concat(m.samples, "|")
		local queued = Ed.Run(function()
			local seed = Ed.SHA512(pool):sub(1, 32)
			local pub = Ed.PublicKey(seed)
			return { seed = seed, pub = pub, id = KeyIdOf(pub) }
		end, function(ok, res)
			if making ~= m then return end
			making = nil
			if not ok or type(res) ~= "table" or ns.me ~= m.me or Link.Key() then return end
			local seed = Ed.ToB64(res.seed)
			Store().keys[m.me] = { id = res.id, seed = seed, auto = true }
			pubCache, ownCert, toldCert, auto = { id = res.id, seed = seed, pub = res.pub }, nil, false, {}
			ns.Print(L.LINK_KEY_MADE:format(res.id))
			ns.Log("discord link: a High Council confirmer key made (%s)", res.id)
			WantAuthor()
		end)
		if not queued then making = nil end
	end
	Link.nextFrame(Frame)
	return true
end

-- Every tick: a councillor of the signed list with no key gets one (unless its key was turned
-- off: /syl discord key off); with its own key made here and no certificate, it listens for the
-- author (Comm.senderHook). An ask unanswered for CA_WAIT counts as refused. Nothing happens
-- unless the council authority's path runs (Link.CouncilAuthority: the author's switch, off by
-- default, the authority's key and the bot's).
function Link.CouncilKeyStep(now)
	if not Link.CouncilAuthority() or not ns.IsHighCouncillor(ns.me) or not Link.ValidName(ns.me) then return end
	local k = Link.Key()
	if not k then
		local d = ns.db and ns.db.discord
		if type(d) == "table" and type(d.nokey) == "table" and d.nokey[ns.me] then return end
		if not making then Link.MakeCouncilKey() end
		return
	end
	if not k.auto or MyCert(k) then return end
	if auto.askedAt and not auto.refusedAt and now - auto.askedAt >= Link.CA_WAIT then auto.refusedAt = now end
	WantAuthor()
end

-- Comm.lua calls this with every sender it admits while we wait for the author (and only then):
-- a message of his (the name the server stamped, on his realm group) and our certificate is
-- asked for: once a session, and again after a refusal only CA_AGAIN after it.
function Link.HeardFrom(sender)
	local W = ns.Workshop
	if not W or not W.IsAuthorName(sender) then return end
	local k = Link.Key()
	if not k or not k.auto or MyCert(k) or not ns.IsHighCouncillor(ns.me) or not Link.CouncilAuthority() then
		if ns.Comm.senderHook == Link.HeardFrom then ns.Comm.senderHook = nil end
		return
	end
	local now = ns.Now()
	if auto.askedAt then
		if not auto.refusedAt then
			if now - auto.askedAt < Link.CA_WAIT then return end
			auto.refusedAt = now
		end
		if now - auto.refusedAt < Link.CA_AGAIN then return end
	end
	local to = ns.FullName(sender)
	auto.askedAt, auto.refusedAt = now, nil
	local asked = auto
	Link.PublicKey(function(pub)
		if auto ~= asked or not Link.Key() or Link.Key().seed ~= k.seed then return end
		ns.Comm.Whisper(to, "DC~1~" .. Ed.ToB64(pub), "linkca", true)
		ns.Log("discord link: asked the author's client for a certificate")
	end)
end

-- The author's certificate for our key (DE): only from him, only once we asked, and checked (the
-- council authority's signature, our key's id and public half, this character, tier c, the
-- expiry) before it is kept; then our addon says it is online. Anything else counts as a refusal.
function Link.HandleCertificate(dist, sender, text)
	if dist ~= "WHISPER" or type(text) ~= "string" or not ns.Workshop or not ns.Workshop.IsAuthorName(sender) or not Link.CouncilAuthority() then return end
	local k, seed = Link.Key()
	if not k or not k.auto or not auto.askedAt or MyCert(k) then return end
	local c = Link.ParseCert(text:match("^DE~(OLK2%.[^~]+)$"))
	if not c or c.id ~= k.id or c.name ~= ns.me or c.tier ~= "c" or c.exp <= ServerTime() then
		auto.refusedAt = ns.Now()
		return
	end
	local asked, cached = auto, CachedPub(k)
	local queued = Ed.Run(function()
		local pub = cached or Ed.PublicKey(seed)
		return { pub = pub, ok = Ed.ToB64(pub) == c.pub and SignedBy(c, true) == "ca" }
	end, function(ok, res)
		local k2 = Link.Key()
		if not k2 or k2.seed ~= k.seed or auto ~= asked then return end
		if not ok or type(res) ~= "table" or not res.ok then
			auto.refusedAt = ns.Now()
			ns.Log("discord link: a certificate from the author's client that doesn't check: left out")
			return
		end
		pubCache = { id = k.id, seed = k.seed, pub = res.pub }
		k2.cert = c.text
		ownCert, toldCert = { cert = c.text, seed = k.seed, ok = true }, false
		auto = {}
		if ns.Comm.senderHook == Link.HeardFrom then ns.Comm.senderHook = nil end
		ns.Print(L.LINK_CERT_AUTO:format(c.id, Days(c.exp - ServerTime())))
		lastAnnounce = -math.huge
		Link.Announce(true)
	end)
	if not queued then auto.refusedAt = ns.Now() end
end

-- The council authority's seed (32 bytes), on the author's own computer only (dist/LinkCA.lua):
-- never printed, logged, sent or written anywhere by the addon.
local function CASeed()
	local s = ns.LINK_CA_SEED
	local seed = type(s) == "string" and #s == 43 and Ed.FromB64(s)
	return seed and #seed == 32 and seed or nil
end

-- The author's client is the council authority: it holds the seed, and it is his character.
function Link.IsCA() return CASeed() ~= nil and ns.Workshop ~= nil and ns.Workshop.IsAuthor() end

-- The council authority's record of every certificate it signed, in the author's SavedVariables
-- (SylvanistasDB.discord.certified[keyId] = { name, pub, exp, t }): which key it certified for which
-- councillor, until when. A public key is certified for one character only (another councillor
-- who sends it, read off its owner's DV, gets nothing), and the list says what the bot's keeper
-- can revoke (/syl discord certified). Nil on every other client.
function Link.Certified()
	local d = ns.db and ns.db.discord
	return type(d) == "table" and type(d.certified) == "table" and d.certified or nil
end

-- The character a public key (base64url) was certified for, or nil.
local function CertifiedFor(pubB64)
	for _, e in pairs(Link.Certified() or {}) do
		if type(e) == "table" and e.pub == pubB64 then return e.name end
	end
	return nil
end

-- A certificate signed: recorded (the same key again for the same character updates its end).
-- Records of certificates that ended a year ago go; past CA_LOG_MAX, the ones that end first.
local function RecordCertified(id, name, pubB64, exp)
	local d = Store()
	if type(d.certified) ~= "table" then d.certified = {} end
	local log, server = d.certified, ServerTime()
	log[id] = { name = name, pub = pubB64, exp = exp, t = server }
	local n = 0
	for k, e in pairs(log) do
		if type(e) ~= "table" or type(e.name) ~= "string" or (tonumber(e.exp) or 0) + Link.CA_DAYS * 86400 < server then
			log[k] = nil
		else
			n = n + 1
		end
	end
	while n > Link.CA_LOG_MAX do
		local first
		for k, e in pairs(log) do
			if k ~= id and (not first or tonumber(e.exp) < tonumber(log[first].exp)) then first = k end
		end
		log[first], n = nil, n - 1
	end
end

-- A councillor's ask (DC): answered with its certificate only for a High Councillor of the signed
-- list (the name the server stamped) on our realm group, for a public key this authority never
-- certified for another character, one per councillor in CA_GAP and CA_HOUR an hour in all,
-- signed in a job, and recorded. Nothing is said to anyone else. The authority's key must be one
-- this version knows (ns.LINK_CA_KEYS): else it certifies nothing (a line in the log, once).
function Link.HandleCertRequest(dist, sender, text)
	if dist ~= "WHISPER" or type(text) ~= "string" or caPub == false or not Link.IsCA() or not Link.CouncilAuthority() then return end
	local seed = CASeed()
	local name, now = ns.FullName(sender), ns.Now()
	local pubB64 = text:match("^DC~1~([%w_%-]+)$")
	if not pubB64 or not Pub(pubB64) or not Link.ValidName(name) then return end
	if not ns.IsHighCouncillor(name) or ns.GroupOf(ns.RealmOf(name) or "") ~= ns.GroupOf(ns.RealmOf(ns.me) or "") then return end
	local holder = CertifiedFor(pubB64)
	if holder and holder ~= name then
		-- Another councillor's key (its public half is in every DV of it): never theirs.
		ns.Log("discord link: a key certified for another High Councillor was sent: refused")
		return
	end
	if ca.given[name] and now - ca.given[name] < Link.CA_GAP then return end
	while ca.hour[1] and now - ca.hour[1] >= 3600 do table.remove(ca.hour, 1) end
	if #ca.hour >= Link.CA_HOUR or Ed.Busy() >= Ed.MAX_JOBS then return end
	ca.given[name] = now
	ca.hour[#ca.hour + 1] = now
	local exp, known = ServerTime() + Link.CA_DAYS * 86400, caPub
	local queued = Ed.Run(function()
		local capub = known or Ed.PublicKey(seed)
		local listed = false
		for _, pk in ipairs(Link.CAKeys()) do listed = listed or pk == capub end
		if not listed then return { listed = false } end
		local pub = Ed.FromB64(pubB64)
		if not Ed.ValidPublicKey(pub) then return { listed = true, capub = capub } end
		local id = KeyIdOf(pub)
		local signed = ("OLK2.%s.%s.c.%d.%s"):format(id, pubB64, exp, name)
		return { listed = true, capub = capub, id = id, cert = signed .. "." .. Ed.ToB64(Ed.Sign(seed, signed, capub)) }
	end, function(ok, res)
		if not ok or type(res) ~= "table" then return end
		if not res.listed then
			if caPub ~= false then ns.Log("discord link: this client's council authority key is not in ns.LINK_CA_KEYS: it certifies nothing") end
			caPub = false
			return
		end
		caPub = res.capub
		if not res.cert then return end
		-- (Two councillors who sent the same key at once: the first one signed keeps it.)
		local holder2 = CertifiedFor(pubB64)
		if holder2 and holder2 ~= name then return end
		RecordCertified(res.id, name, pubB64, exp)
		stats.certified = stats.certified + 1
		ns.Comm.Whisper(name, "DE~" .. res.cert, "linkcert:" .. name, true)
		ns.Log("discord link: certified a High Councillor's key")
	end)
	if not queued then
		ca.given[name] = nil
		table.remove(ca.hour)
	end
end

---------------------------------------------------------------------------
-- The window: the QR code of the link, drawn with textures on white, each module a whole
-- number of screen pixels (3 at least, 4 when it fits on the screen) at the player's UI scale,
-- and the link in a read-only copy box. Our own window on UIParent: movable, closed by its X
-- (and by Escape with mouse and keyboard, ns.EscapeCloses); not a UI panel, and its box takes
-- the keyboard only when clicked (the gamepad UI's rule, ns.Focus).
---------------------------------------------------------------------------

-- The QR code of a link: level M when it fits a version 15 code, else L. pause: Ed.Pause when
-- made inside a job. No pcall around the encoder: its pause yields the job's coroutine, and the
-- game's Lua 5.1 can't yield across a pcall (the job itself catches an error: Ed.Run's resume).
function Link.Matrix(url, pause)
	if qr.url == url then return qr.matrix, qr.level end
	local enc = ns.QREncode
	if type(enc) ~= "table" or type(url) ~= "string" then return nil end
	local level = #url <= Link.M_MAX_BYTES and 2 or 1
	local done, matrix = enc.qrcode(url, level, nil, pause)
	if not done or type(matrix) ~= "table" then return nil end
	qr = { url = url, matrix = matrix, level = level }
	return matrix, level
end

-- The dark modules as few rectangles: the runs of each row, a run the next row repeats
-- growing down. { x, y, w, h } in modules from the top left (0-based).
function Link.Rects(matrix)
	local n, out, open = #matrix, {}, {}
	for y = 1, n do
		local nextOpen, x = {}, 1
		while x <= n do
			if matrix[x][y] > 0 then
				local x2 = x
				while x2 < n and matrix[x2 + 1][y] > 0 do x2 = x2 + 1 end
				local k = x * 1000 + x2
				local rect = open[k]
				if rect then
					rect.h = rect.h + 1
				else
					rect = { x = x - 1, y = y - 1, w = x2 - x + 1, h = 1 }
					out[#out + 1] = rect
				end
				nextOpen[k] = rect
				x = x2 + 1
			else
				x = x + 1
			end
		end
		open = nextOpen
	end
	return out
end

-- UI units of one screen pixel for this frame, and the screen's height in pixels.
local function PixelSize(f)
	local h
	if GetPhysicalScreenSize then h = select(2, GetPhysicalScreenSize()) end
	h = tonumber(h) or 0
	if h <= 0 then h = 1080 end
	local scale = f and f.GetEffectiveScale and f:GetEffectiveScale() or 1
	if not scale or scale <= 0 then scale = 1 end
	return 768 / h / scale, h
end
Link.PixelSize = PixelSize

-- Screen pixels per module: about half the screen's height for the whole code; 4 at least when
-- the window still fits on the screen, else 3.
function Link.ModulePixels(modules, screenH, chromePx)
	screenH = tonumber(screenH) or 1080
	local want = math.max(4, math.floor(screenH * 0.5 / modules))
	local room = math.floor((screenH - (chromePx or 0)) / modules)
	return math.max(3, math.min(want, room))
end

-- The window's top left on a whole screen pixel, so each module's edges are too.
local function Snap(f)
	local px = PixelSize(f)
	local left, top = f:GetLeft(), f:GetTop()
	if not left or not top then return end
	f:ClearAllPoints()
	f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", math.floor(left / px + 0.5) * px, math.floor(top / px + 0.5) * px)
end

local function MakeWindow()
	local f = CreateFrame("Frame", "SylvanistasLinkFrame", UIParent)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		Snap(self)
	end)
	f:SetPoint("CENTER")
	f:Hide()
	local okBorder, border = pcall(CreateFrame, "Frame", nil, f, "DialogBorderTemplate")
	if not okBorder or not border then
		border = f:CreateTexture(nil, "BACKGROUND")
		border:SetColorTexture(0, 0, 0, 0.9)
	end
	border:SetAllPoints()
	f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	f.title:SetPoint("TOP", 0, -18)
	f.title:SetText(L.LINK_TITLE)
	f.close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	f.close:SetPoint("TOPRIGHT", -4, -4)
	f.close:SetScript("OnClick", function() f:Hide() end)
	f.name = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.name:SetPoint("TOP", 0, -42)
	f.canvas = CreateFrame("Frame", nil, f)
	f.canvas.bg = f.canvas:CreateTexture(nil, "BACKGROUND")
	f.canvas.bg:SetColorTexture(1, 1, 1, 1)
	f.canvas.bg:SetAllPoints()
	f.modules = {}
	f.hint = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	f.hint:SetPoint("TOP", f.canvas, "BOTTOM", 0, -12)
	f.hint:SetJustifyH("CENTER")
	f.copyLabel = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	f.copyLabel:SetPoint("TOP", f.hint, "BOTTOM", 0, -10)
	f.copyLabel:SetText(L.LINK_COPY)
	local okBox, eb = pcall(CreateFrame, "EditBox", "SylvanistasLinkCopyBox", f, "InputBoxTemplate")
	if not okBox or not eb then eb = CreateFrame("EditBox", nil, f) end
	eb:SetHeight(22)
	eb:SetPoint("TOP", f.copyLabel, "BOTTOM", 0, -6)
	eb:SetAutoFocus(false)
	eb:SetFontObject("ChatFontNormal")
	eb.sylvanistasBox = true
	-- Read only: whatever is typed, the link comes back, selected for Ctrl+C.
	eb:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(f.url or "")
			self:HighlightText()
		end
	end)
	eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.copy = eb
	f:SetScript("OnHide", function(self)
		if self:IsShown() then return end -- the whole interface hidden (Alt+Z): still open
		self.copy:ClearFocus()
	end)
	return f
end

-- The window drawn for this link: the code at whole pixels, sized around it.
local function Fill(f, bundle, b, rec, matrix)
	local url = Link.URL(bundle)
	f.url, f.bundle = url, bundle
	local px, screenH = PixelSize(f)
	local modules = #matrix + 2 * Link.QUIET
	local mpx = Link.ModulePixels(modules, screenH, math.ceil(Link.CHROME / px))
	local m = mpx * px
	local sizePx = modules * mpx
	local widthPx = math.max(sizePx + 48, math.ceil(420 / px))
	local leftPx, topPx = math.floor((widthPx - sizePx) / 2), math.ceil(66 / px)
	f.modulePixels, f.codePixels = mpx, sizePx
	f:SetWidth(widthPx * px)
	f:SetHeight(topPx * px + sizePx * px + Link.CHROME - 66)
	local canvas = f.canvas
	canvas:ClearAllPoints()
	canvas:SetPoint("TOPLEFT", f, "TOPLEFT", leftPx * px, -topPx * px)
	canvas:SetSize(sizePx * px, sizePx * px)
	local rects = Link.Rects(matrix)
	for i, rect in ipairs(rects) do
		local t = f.modules[i]
		if not t then
			t = canvas:CreateTexture(nil, "ARTWORK")
			t:SetColorTexture(0, 0, 0, 1)
			f.modules[i] = t
		end
		t:ClearAllPoints()
		t:SetPoint("TOPLEFT", canvas, "TOPLEFT", (Link.QUIET + rect.x) * m, -(Link.QUIET + rect.y) * m)
		t:SetSize(rect.w * m, rect.h * m)
		t:Show()
	end
	for i = #rects + 1, #f.modules do f.modules[i]:Hide() end
	f.shownModules = #rects
	local by = rec.council and L.LINK_BY_COUNCIL or L.LINK_BY_PLAYERS:format(#b.proofs)
	f.name:SetText(ns.DisplayName(b.requester) .. "  |cff9d9d9d·  " .. by .. "|r")
	f.hint:SetWidth(widthPx * px - 40)
	f.hint:SetText(L.LINK_SCAN:format(Link.WatcherLabel()))
	f.copy:SetWidth(widthPx * px - 60)
	f.copy:SetText(url)
	f.copy:SetCursorPosition(0)
	return true
end

local function Open(bundle, b, rec, matrix)
	frame = frame or MakeWindow()
	Fill(frame, bundle, b, rec, matrix)
	local was = frame:IsShown()
	frame:Show()
	if not was then Snap(frame) end
	ns.EscapeCloses("SylvanistasLinkFrame")
end

-- /syl discord show, and when a proof is ready. The QR code is made in a job (a big one takes
-- a few frames), then the window opens.
function Link.ShowWindow(fromCommand)
	local rec = Store().chars[ns.me]
	local bundle = type(rec) == "table" and (rec.state == "ready" or rec.state == "delivered") and rec.bundle or nil
	local b = Link.Parse(bundle)
	if not b or b.requester ~= ns.me then
		if fromCommand then ns.Print(type(rec) == "table" and rec.state == "waiting" and L.LINK_STILL_WAITING or L.LINK_NOTHING) end
		return false
	end
	local url = Link.URL(bundle)
	if qr.url == url then
		Open(bundle, b, rec, qr.matrix)
		return true
	end
	if qrJob == url then return true end
	qrJob = url
	local queued = Ed.Run(function() return Link.Matrix(url, Ed.Pause) end, function(ok, matrix)
		if qrJob == url then qrJob = nil end
		if not ok then ns.Log("discord link: the QR code failed: %s", tostring(matrix)) end
		-- (Forgotten or replaced meanwhile: nothing to show.)
		if not ok or type(matrix) ~= "table" or Store().chars[ns.me] ~= rec or rec.bundle ~= bundle then return end
		Open(bundle, b, rec, matrix)
	end)
	-- No room for the job (the queue is full): nothing is being made, so the next try makes it.
	if not queued then qrJob = nil end
	return queued
end

function Link.HideWindow()
	if frame then frame:Hide() end
end

function Link.Window() return frame end

---------------------------------------------------------------------------
-- Commands, dialogs, status
---------------------------------------------------------------------------

-- The code typed or pasted: checked first (the bot's signature, the expiry), then the player's
-- yes (nothing is sent before it).
function Link.Enter(text)
	local t = Link.ParseToken(text)
	if not t then return ns.Print(L.LINK_CODE_BAD) end
	if #Link.BackendKeys() == 0 then return ns.Print(L.LINK_NOT_OPEN) end
	local now = ServerTime()
	if t.exp <= now then return ns.Print(L.LINK_CODE_EXPIRED) end
	if t.exp > now + Link.CODE_TTL_MAX then return ns.Print(L.LINK_CODE_BAD) end
	ns.Print(L.LINK_CHECKING)
	local queued = Ed.Run(function() return BotSigned(t) end, function(ok, valid)
		if not ok or not valid then return ns.Print(L.LINK_CODE_BAD) end
		if t.exp <= ServerTime() then return ns.Print(L.LINK_CODE_EXPIRED) end
		if not ns.IsMember() then return ns.Print(L.LINK_NOT_MEMBER) end
		local who = ns.DisplayName(ns.me) or "?"
		ns.ShowDialog("SYLVANISTAS_LINK_CONSENT", L.LINK_CONSENT:format(who, t.user, t.user), nil, t)
	end)
	if not queued then ns.Print(L.LINK_BUSY) end
end

function Link.Forget()
	Store().chars[ns.me] = nil
	req, delivery, waitWatcher = nil, nil, false
	wipe(sentTo)
	Link.HideWindow()
	ns.Print(L.LINK_FORGOTTEN)
end

-- /syl discord status: every character of the account with a request or a proof.
function Link.PrintStatus()
	local d, now, server = Store(), ns.Now(), ServerTime()
	local list = {}
	for name, rec in pairs(d.chars) do
		if type(rec) == "table" then list[#list + 1] = name end
	end
	table.sort(list)
	ns.Print(L.LINK_TITLE)
	for _, name in ipairs(list) do
		local rec = d.chars[name]
		local who = ns.DisplayName(name)
		if rec.state == "waiting" and tonumber(rec.claimedAt) then
			print(L.LINK_STATUS_CLAIMED:format(who, math.max(1, math.ceil((Link.CLAIMED_WAIT - (now - rec.claimedAt)) / 60))))
		elseif rec.state == "waiting" then
			local n = 0
			for _, p in pairs(type(rec.proofs) == "table" and rec.proofs or {}) do
				if p.c or FreshP(p, now) then n = n + 1 end
			end
			local need = rec.mode == "a" and L.LINK_NEED_PLAYERS:format(math.min(n, Link.NEEDED), Link.NEEDED) or L.LINK_NEED_COUNCIL
			print(L.LINK_STATUS_WAITING:format(who, need, Hours((tonumber(rec.exp) or server) - server)))
		elseif rec.state == "ready" then
			local left = (tonumber(rec.exp) or server) + Link.DELIVER_UNTIL - server
			print(left > 0 and L.LINK_STATUS_READY:format(who, Link.WatcherLabel(), Days(left)) or L.LINK_STATUS_SCAN_ONLY:format(who))
		elseif rec.state == "delivered" then
			print(L.LINK_STATUS_DELIVERED:format(who, Link.WatcherLabel()))
		end
	end
	if #list == 0 then print(L.LINK_STATUS_NONE) end
	local key = Link.Key()
	local c = key and MyCert(key)
	if key then
		print(L.LINK_STATUS_KEY:format(key.id, c and L.LINK_STATUS_CERT:format(TierName(c.tier), Days(c.exp - server))
			or (key.auto and L.LINK_STATUS_AUTOCERT or L.LINK_STATUS_NOCERT)))
	else
		print(L.LINK_STATUS_NOKEY)
	end
	if ns.IsHighCouncillor(ns.me) then
		local n = InboxCount(d.inbox)
		print(Link.Watching() and L.LINK_STATUS_WATCHER_ON:format(n) or L.LINK_STATUS_WATCHER_OFF)
	end
end

-- /syl discord certified: the council authority's record (the author's client), for the bot's
-- keeper, who can revoke a key by its id or every key of a character (web/WORKER.md, step 1b).
function Link.PrintCertified()
	local list = {}
	for id, e in pairs(Link.Certified() or {}) do
		if type(e) == "table" and type(e.name) == "string" and tonumber(e.exp) then
			list[#list + 1] = { id = tostring(id), name = e.name, exp = tonumber(e.exp) }
		end
	end
	if #list == 0 then return ns.Print(L.LINK_CA_LOG_NONE) end
	table.sort(list, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		return a.exp < b.exp
	end)
	ns.Print(L.LINK_CA_LOG:format(#list))
	for _, e in ipairs(list) do print(L.LINK_CA_LOG_LINE:format(e.id, e.name, date("!%Y-%m-%d", e.exp))) end
end

-- One line for /syl status and the bug report: never the key itself, the code or a proof.
function Link.StatusLine()
	local key, now = Link.Key(), ns.Now()
	local c, p = 0, 0
	for name, a in pairs(announcers) do
		if now - a.t <= Link.ANNOUNCE_FRESH then
			if IsCouncillor(name, a) then c = c + 1 elseif a.tier == "p" then p = p + 1 end
		end
	end
	local rec = ns.db and type(ns.db.discord) == "table" and type(ns.db.discord.chars) == "table" and ns.db.discord.chars[ns.me]
	local state = type(rec) == "table" and tostring(rec.state) or "none"
	if req then
		local asked = 0
		for _ in pairs(req.asked) do asked = asked + 1 end
		state = state .. (" (mode %s, %d asked)"):format(tostring(req.rec.mode), asked)
	end
	local inbox = 0
	if ns.db and type(ns.db.discord) == "table" and type(ns.db.discord.inbox) == "table" then inbox = InboxCount(ns.db.discord.inbox) end
	local cert = key and MyCert(key)
	local keyText = "none"
	if key then
		keyText = key.id .. (key.auto and " (made here)" or "") .. (cert and (" as %s, certificate %s"):format(cert.tier,
			ownCert and ownCert.cert == cert.text and (ownCert.ok and "checked" or "wrong") or "not checked yet") or ", no certificate")
		if not cert and key.auto then keyText = keyText .. (auto.askedAt and (auto.refusedAt and ", refused" or ", asked") or ", not asked yet") end
	end
	local caText = Link.IsCA() and ("  |  council authority %s, %d certified"):format(caPub == false and "not in LINK_CA_KEYS"
		or (Link.CouncilAuthority() and "on" or "off"), stats.certified) or ""
	return ("key %s  |  this character %s  |  confirmers online c=%d p=%d  |  watchers online %d  |  watcher %s, inbox %d  |  confirmed %d, refused %d, bad proofs %d, bad certificates %d, bad links %d  |  jobs %d%s"):format(
		keyText, state, c, p, #OnlineWatchers(now), Link.Watching() and "on" or "off",
		inbox, stats.confirmed, stats.refused, stats.badProofs, stats.badCerts, stats.badBundles, Ed.Busy(), caText)
end

-- /syl discord [code | show | status | forget | key [<id> <key> | new | off] | cert [<certificate>] |
-- watcher on|off | certified]
function Link.Slash(rest)
	rest = tostring(rest or ""):match("^%s*(.-)%s*$")
	local verb, arg = rest:match("^(%S*)%s*(.-)$")
	verb = (verb or ""):lower()
	if rest == "" then
		ns.ShowDialog("SYLVANISTAS_LINK_CODE")
	elseif verb == "show" and arg == "" then
		Link.ShowWindow(true)
	elseif verb == "status" and arg == "" then
		Link.PrintStatus()
	elseif verb == "certified" and arg == "" then
		Link.PrintCertified()
	elseif verb == "forget" and arg == "" then
		Link.Forget()
	elseif verb == "key" then
		Link.SetKey(arg)
	elseif verb == "cert" then
		Link.SetCert(arg)
	elseif verb == "watcher" then
		local on = arg:lower()
		if on == "on" or on == "off" then
			Link.SetWatcher(on == "on")
		elseif Link.Watching() then
			ns.Print(L.LINK_WATCHER_ON:format((InboxCount(Store().inbox))))
		else
			ns.Print(ns.IsHighCouncillor(ns.me) and L.LINK_WATCHER_OFF or L.LINK_WATCHER_ONLY)
		end
	else
		Link.Enter(rest)
	end
end

StaticPopupDialogs["SYLVANISTAS_LINK_CODE"] = {
	text = L.LINK_PASTE_PROMPT,
	button1 = L.LINK_CONTINUE,
	button2 = CANCEL or "Cancel",
	hasEditBox = true,
	maxLetters = 200,
	editBoxWidth = 300,
	OnAccept = function(self)
		local eb = self.editBox or self.EditBox
		local text = eb and eb:GetText() or ""
		ns.SafeCall("discord code", Link.Enter, text)
	end,
	EditBoxOnEnterPressed = function(self)
		local text = self:GetText()
		self:GetParent():Hide()
		ns.SafeCall("discord code", Link.Enter, text)
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- The sentence comes whole (the username twice): "%s" and the text as its argument.
StaticPopupDialogs["SYLVANISTAS_LINK_CONSENT"] = {
	text = "%s",
	button1 = L.LINK_ACCEPT,
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data)
		ns.SafeCall("discord link", Link.Start, data or (self and self.data))
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Login and the ticker
---------------------------------------------------------------------------

local function Restore(rec, server)
	if type(rec) ~= "table" or rec.state ~= "waiting" or not Code(rec.R) or not User(rec.user) or not Nonce(rec.nonce) or not Tag(rec.tag)
		or not Threshold(rec.T) or not Link.ValidGuild(rec.guild) or not FACTIONS[rec.faction] or (rec.mode ~= "c" and rec.mode ~= "a") then
		return nil
	end
	local proofs = {}
	for name, p in pairs(type(rec.proofs) == "table" and rec.proofs or {}) do
		-- (Kept only once their signature checked: the SavedVariables are this player's own.)
		if ValidProof(p) and p.confirmer == name and tonumber(p.got) then proofs[name] = p end
	end
	rec.proofs = proofs
	-- Enough proofs that only claimed the guild, kept while it waits for one that knows it.
	local fallback = type(rec.fallback) == "table" and rec.fallback or nil
	for _, p in ipairs(fallback or {}) do
		if not ValidProof(p) then fallback = nil break end
	end
	if not fallback or #fallback == 0 or not tonumber(rec.claimedAt) then fallback = nil end
	rec.fallback, rec.claimedAt = fallback, fallback and tonumber(rec.claimedAt) or nil
	if (tonumber(rec.exp) or 0) <= server and not fallback then return nil end
	return Runtime(rec)
end

-- At login: this character's request waiting comes back; what expired goes (a proof waiting
-- for a watcher once the bot can't take it any more: GRACE after its code's expiry). The confirmer
-- key 0.9.10's first builds kept for the whole account goes: a key is one character's now. Keys
-- made in game go too while the council authority's path is off (Link.CouncilAuthority).
function Link.Resume()
	if type(ns.db.discord) ~= "table" then return end -- never used on this account
	local d, server = Store(), ServerTime()
	if d.key ~= nil or d.cert ~= nil then
		d.key, d.cert = nil, nil
		ns.Print(L.LINK_KEY_PER_CHARACTER)
	end
	-- Keys an addon made in game for a High Councillor (auto) go, every character's of the account,
	-- while the council authority's path does not run (Konig's review: made from tens of bits,
	-- kept in plain text, certified for a year): said in one line. Keys from the bot's keeper stay.
	if not Link.CouncilAuthority() then
		local gone = false
		for name, k in pairs(d.keys) do
			if type(k) == "table" and k.auto then d.keys[name], gone = nil, true end
		end
		if gone then
			pubCache, ownCert, ownChecking, toldCert, making, auto = nil, nil, nil, false, nil, {}
			if ns.Comm.senderHook == Link.HeardFrom then ns.Comm.senderHook = nil end
			ns.Print(L.LINK_KEY_AUTO_GONE)
			ns.Log("discord link: keys made in game removed (the council authority's path is off)")
		end
	end
	local expired = false
	for name, rec in pairs(d.chars) do
		local keep = type(rec) == "table"
		if keep and rec.state == "waiting" then
			keep = (tonumber(rec.exp) or 0) > server or type(rec.fallback) == "table"
			if not keep and name == ns.me then expired = true end
		elseif keep then
			keep = (rec.state == "ready" or rec.state == "delivered") and server < (tonumber(rec.exp) or 0) + Link.GRACE
		end
		if not keep then d.chars[name] = nil end
	end
	local now = ns.Now()
	for name, times in pairs(d.given) do
		if type(times) ~= "table" or type(times[#times]) ~= "number" or now - times[#times] >= 86400 then d.given[name] = nil end
	end
	PruneInbox(d.inbox, now)
	local rec = d.chars[ns.me]
	req = Restore(rec, server)
	if req then
		ns.Print(L.LINK_RESUMED)
	elseif type(rec) == "table" and rec.state == "waiting" then
		d.chars[ns.me] = nil
	elseif type(rec) == "table" and rec.state == "ready" then
		ns.Print(Deliverable(rec) and L.LINK_READY_REMINDER:format(Link.WatcherLabel()) or L.LINK_READY_SCAN)
	elseif expired then
		ns.Print(L.LINK_EXPIRED)
	end
end

function Link.Tick()
	local now = ns.Now()
	if now - lastPrune >= 60 then Prune(now) end
	Link.CouncilKeyStep(now)
	Link.Announce()
	Link.AnnounceWatcher()
	if req then Link.Step(now) end
	Link.Deliver(now)
end

-- At login: the request or proof of this character back; the ticker says we are online (a key
-- holder with its certificate, a watcher) at its first tick, then every ANNOUNCE_EVERY.
function Link.Login()
	Link.Resume()
	ns.Every(5, "discord link", Link.Tick)
end
ns.On("LOGIN", function() Link.Login() end)

ns.Comm.Handle("DV", function(...) Link.HandleAnnounce(...) end)
ns.Comm.Handle("DR", function(...) Link.HandleRequest(...) end)
ns.Comm.Handle("DA", function(...) Link.HandleAnswer(...) end)
ns.Comm.Handle("DW", function(...) Link.HandleWatcher(...) end)
ns.Comm.Handle("DB", function(...) Link.HandleBundle(...) end)
ns.Comm.Handle("DK", function(...) Link.HandleAck(...) end)
ns.Comm.Handle("DC", function(...) Link.HandleCertRequest(...) end)
ns.Comm.Handle("DE", function(...) Link.HandleCertificate(...) end)

-- Tests start from a clean state.
function Link.Request() return req end
function Link.Announcers() return announcers end
function Link.Watchers() return watchers end
function Link.Delivery() return delivery end
function Link.Stats() return stats end
function Link.Certs() return certs end
function Link.QRJob() return qrJob end
function Link.Making() return making end
function Link.Reset()
	req, delivery, waitWatcher, pubCache, qrJob, ownCert, ownChecking, toldCert = nil, nil, false, nil, nil, nil, nil, false
	announced, making, auto, caPub = nil, nil, {}, nil
	ca = { given = {}, hour = {} }
	if ns.Comm.senderHook == Link.HeardFrom then ns.Comm.senderHook = nil end
	wipe(announcers); wipe(watchers); wipe(recent); wipe(sentTo); wipe(inboxTried); wipe(certs); wipe(certJobs); wipe(certNewAt); wipe(checking)
	inAsm = ns.Codec.NewAssembler()
	nAnnouncers, nCerts, nCertJobs, nChecking, lastAnnounce, lastWatch, lastPrune = 0, 0, 0, 0, -math.huge, -math.huge, -math.huge
	for k in pairs(stats) do stats[k] = 0 end
	qr = {}
	if frame then frame:Hide() end
	frame = nil
end
