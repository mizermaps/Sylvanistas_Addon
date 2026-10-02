# Sylvanistas addon: limitations and next steps

A full rebrand of the **Olympus** addon (v1.1.2, MIT) for the **Horde** guild **<Sylvanistas>**.
Guild master: **Testiana Paladina**. Main command: `/syl`.

This file lists what to expect from the current build, then the steps to turn it from
"Olympus renamed" into Sylvanistas's own addon, separate from Olympus on the Alliance.

---

## Part 1: Limitations

### 1.1 Testing so far
- It loads and runs in the game. All 61 Lua files pass a syntax check.
- Lightly tested so far. Features nobody has used yet (Treasury, Vox polls, decrees, the Board) may still have runtime errors.
  Turn on `/console scriptErrors 1` and report anything with `/syl bug`.

### 1.2 Layer hop
| Limit | Why |
|---|---|
| Only members running this addon can help | Requests go over Sylvanistas's own hidden channel. Olympus players and outsiders never see them. |
| Helpers must opt in | Each helper needs **"share my zone and layer"** and **"layer help"** turned on (`/syl privacy`). Both are off by default. |
| **Testiana never helps** | `Hop.lua:142` leaves the King out on purpose. To reach her layer, *another* opted-in member on that layer sends the invite. |
| Layer detection needs NPCs | Layers come from NPC IDs nearby. In empty areas the layer is unknown, and it counts as stale after 10 minutes. |
| Clicks required | Forever only allows invites and accepting them from a real click. With the gamepad UI nothing is automatic. |
| Rate limits | One request every 20 seconds, with longer waits (20s, 60s, 180s) after failed tries. |
| Experimental | The original authors marked layer detection "experimental until tested on a live realm". |

**Minimum test setup:** two ordinary members, both opted in, on different layers of the same zone.
**Hopping to Testiana:** Testiana online, an opted-in member on her layer, and the member who asks.

### 1.3 Placeholder roles (do nothing until filled in)
| Role | Setting (`Core.lua`, top) | Missing until set |
|---|---|---|
| Addon author | `ns.AUTHOR_CHARACTER` | Workshop tab, version roll calls, "please update" messages, in-game bug reports |
| Treasurer | `ns.TREASURER_CHARACTER` | Treasury book, keepers |
| Treasurer's mail character | `ns.TREASURER_MAIL_CHARACTER` | Where dues go. ⚠️ "Pay dues" currently fills in a mail to `CHANGEME_TreasurerMail`. |
| Realm group | `ns.REALM_GROUP` | The author's and treasurer's checks |
| GM display name | `ns.GM_DISPLAY` | Optional. The crown shows "Testiana Paladina" until it's set. |
| GM realm | `ns.GM_REALM` | Optional. Learned from Testiana's first message (`/syl status`). |

### 1.4 Features that need keys (off)
- **Signed lists**: High Council, Stewards, approved guilds, titles. The Olympus author's RSA key was
  removed (`Sign.lua`), so every signature is refused.
- **Discord link**: needs a bot and Ed25519 keys (`Link.lua`).

### 1.5 Privacy and security
- **The channel is public until an officer runs `/syl key <secret>`.** Before that, anyone who joins
  `SylvanistasNetH` by name can read names, ranks, layers and Testiana's location.
- The key reaches **every guild member** in plain text, so one leak exposes the channel.
  The King can rotate it (`Keys.lua`).
- Officers can kick (one confirmed click each) and the King's Hands can hide players ("net-off"). Choose who holds those roles carefully.

### 1.6 The Forever beta
- The beta currently **wipes addon data at login**. Settings reset and the privacy questions come back
  each session. `/syl backup` and `/syl restore` cover settings, but not privacy answers.
- The game only allows `/who` searches, whispers and guild invites from clicks, never automatically.

### 1.7 Branding and scale
- ✅ Logos replaced with the Sylvanistas "S" emblem (`media/logo64`, `logo128`, `emblem128`; source in `art-source/emblem_v3.png`). The bronze portrait borders and star are generic and stay.
- ✅ Role names are Sylvanistas-themed in English (see Step 4). Translations only rename the Dark Lady so far.
- Translations (de, fr, es, pt-BR) were renamed automatically, so some grammar is off, e.g. "do Sylvanistas".
- The realm-wide census and the voting between guild reports were built for dozens of guilds. With one guild,
  it mostly shows your own roster.
- **No automatic updates from Olympus.** Fixes Olympus releases later won't reach this copy.

---

## Part 2: Next steps

### Step 1: Fill in the roles (5 minutes) ⭐ do first
Edit the settings block at the top of `Core.lua`:

```lua
ns.GM_CHARACTER = "Testiana Paladina"     -- ✅ done
ns.GM_REALM = "ClassicBetaPvE"            -- ✅ done
ns.GM_DISPLAY = "Heir to Sylvanas"        -- ✅ done
ns.AUTHOR_CHARACTER = "Riztosin Psalmpalm" -- ✅ done
ns.REALM_GROUP = "ClassicBetaPvE"         -- ✅ done
ns.TREASURER_CHARACTER = "..."            -- or:
ns.TREASURY_OFF = true                    -- ✅ done (no treasurer yet)
```

✅ `ns.TREASURY_OFF = true` is set: Treasury, Dues and Bank are off until there is a treasurer. To turn them on, fill in the two treasurer names and set it to `false`.

### Step 2: Seal the channel ⭐
An officer runs `/syl key <a long secret>` once. Online members receive it automatically.
Never post the key in public chat or on Discord.

### Step 3: Make your own artwork ✅ done (Sylvanistas "S" emblem)
Replace with your own art at the same sizes, saved as 32-bit TGA files with an alpha channel:
- `media/logo64.tga` (64×64, the minimap and AddOns list icon)
- `media/logo128.tga` (128×128, the window header)
- `media/emblem128.tga` (128×128)
- Optional: `media/borders/*.tga` (portrait borders)

You might also change the addon's gold color `ns.COLOR = "ffe6c35c"` (`Core.lua`) and the
`## Title` color in `Sylvanistas.toc`, for example to a Forsaken purple or green.

### Step 4: Horde-themed role names ✅ done (English)

All Olympus role and feature names in the English text and the in-game help are renamed:

| Olympus | Sylvanistas | Who / what |
|---|---|---|
| King | **the Dark Lady** (display name **Dark Lady**) | the guild master, Testiana |
| Steward | **Ambassador** | her named deputy (needs the signed list) |
| Hands | **Dark Rangers** | helpers she names in game |
| High Council / Councillor | **the Dreadguard / a Dreadguard** | moderators (signed list) |
| Captain | **Dreadguard** | officers, guild rank 0-1 |
| Lord | **Veteran** | guild master of each Sylvanistas guild |
| army | **the Forsaken** | everyone |
| Throne | **Sanctum** | her tab |
| Royal / Crown | **Banshee / the Banshee Queen**, and **the Banshee Court** for her guild's leadership | decrees, inspection, absolution |
| Court | **Audience** | "holds an audience in …" |
| Writs | **Edicts** | her formal letters |
| Pardon | **Absolution** | clears a name from the untabarded list for a week |
| Vox Populi | **Voice of the Forsaken** | her polls |
| Gates | **Portal** | "the portal to <guild> is open": recruiting pin for 2 hours |
| Call to Arms | **Call for the Revenant** | help needed here: soft sound, red marker for 5 min (Will of the Forsaken icon) |
| Muster | **Gathering** | meeting point: soft sound, horn marker for 30 min |
| soldiers | **Forsaken** | the member counts |

**No Wall of Shame:** `ns.WALL_OF_SHAME = false` (`Core.lua`). Tabard checks still run, but the untabarded list stays the Dark Lady's alone; the switch to show it is hidden, and a shared list from anyone else is dropped. Set it to `true` to bring it back.

Pronouns for the Dark Lady are she/her; Ambassadors, Dreadguards and guild masters are "they".

**Not renamed (on purpose or still open):**
- Slash commands keep their old words: `/syc` (Dreadguard chat), `/syld` (Veterans chat),
  `/syl vox`, `/syl mute captains | lords`, `/syl sound royal | court | vox | throne | arms | muster`, `/syl arms`, `/syl muster`.
- German, French, Spanish and Portuguese: only the Dark Lady is renamed (die Dunkle Fürstin,
  la Dame noire, la Dama Oscura, a Dama Sombria). Their other role names are still Olympus-style.
- Code identifiers and comments (`ns.King`, `KING_GUILD`…) are unchanged; players never see them.

### Step 5: Remove what you won't use (optional)
Smaller means faster loading and fewer places for bugs. Candidates:
- **Alliance leftovers**: `ns.CHANNEL` (Alliance channel), Alliance branches in `Comm.ChannelSpec`,
  and the `ns.Stores` split. They're harmless since the addon stays idle on Alliance.
- **Discord Link** (`Link.lua`, `Ed25519.lua`, `libs/QREncode`), if you won't run a bot.
- **Treasury / Dues / Bank**, if the guild doesn't run a shared bank.
- **Tabard inspection** (`Inspect.lua`, King's Royal Inspection), if tabards don't matter to you.

Removing a module means deleting its line in `Sylvanistas.toc` **and** checking for code that calls
it (`ns.<Module>`). Ask me to do this safely.

### Step 6: Set up signing (optional, for High Council, Stewards, approved guilds)
1. Make your own RSA-2048 (e = 3) key pair on your computer and keep the private half private.
2. Put the public values in `Sign.lua` (`Sign.N`, `Sign.MU`).
3. Sign the lists with a script and paste them in game (`/syl approved paste`, etc.).

The original Olympus signing script isn't included. I can write one.

### Step 7: Fully separate from Olympus's protocol (optional)
Sylvanistas already uses its own prefix, channel, saved data, frame and popup names, and backup tag (`SYLB1`).
A few internal message tags still carry Olympus names (`OLY4`, `OLB5`, `OLC2`, `OLK2` in `Link.lua`).
They never cross over, because the prefix differs, but you can rename them for tidiness.

### Step 8: Versioning and distribution
- Restart the version at e.g. `2.0.0-syl`? **Careful:** parts of the code compare version numbers, so a
  non-numeric version would be treated as "unknown". The safest scheme is plain numbers going up from
  `1.1.2`, e.g. `1.2.0`.
- Change `ns.VERSION` (`Core.lua`) and `## Version` (`Sylvanistas.toc`) together.
- For guildmates: zip the `Sylvanistas` folder, or publish on CurseForge or GitHub and fill in the
  links in `UI.lua:2098` and `Sylvanistas.toc` (`X-Website`).
- Keep `LICENSE.txt`. The MIT license requires the Olympus copyright notice to stay.

### Step 9: Keep a source copy
- The working copy lives at `~/Desktop/claude/Sylvanistas`. Edit there, then copy into
  `_classic_beta_/Interface/AddOns/`. Better still, put it in git so every change can be undone.
- To pick up a future Olympus release: the rename can be turned into a script that you rerun on a new
  Olympus version, then you review the differences.

---

## Quick reference

| Command | What it does |
|---|---|
| `/syl` | Open the window |
| `/syl status` | What the addon detects: guild, channel, layer, GM realm |
| `/syl privacy` | Sharing switches (layer, layer help, chats…) |
| `/syl key <secret>` | Seal the guild channel (officers) |
| `/syl backup` / `/syl restore` | Save and restore settings as text |
| `/syl bug` | Copyable error report |
| `/sy`, `/syc`, `/syld` | Guild chats: everyone, Captains, Lords |
