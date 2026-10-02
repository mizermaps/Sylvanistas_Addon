# Sylvanistas addon: setup checklist

A full rebrand of the Olympus addon (v1.1.2, MIT) for the Horde guild **<Sylvanistas>**.
Main command: `/syl` (also `/sylvanistas`). It can be installed next to Olympus: its addon prefix
(`SYLVANISTAS`), hidden channel (`SylvanistasNetH`), saved data (`SylvanistasDB`), frame and popup
names, and backup tag (`SYLB1`) are all its own.

## 1. Fill in the placeholders

Every `CHANGEME_` name below is inert: no real character can have an underscore in its name, so
each role is empty until you fill it in.

| Where | Setting | What to put |
|---|---|---|
| `Core.lua` (top) | `ns.GM_CHARACTER` | **Set: "Testiana Paladina".** This is the "King": Throne tab, crown, "join the GM's layer". |
| `Core.lua` | `ns.GM_REALM` | Their realm group, e.g. `"ClassicBetaPvP"`. Leave `nil` to learn it from their first message (`/syl status` shows it). |
| `Core.lua` | `ns.GM_DISPLAY` | The name shown on the lines and crown. Until it's set, the character's short name is used. |
| `Core.lua` | `ns.AUTHOR_CHARACTER` | Whoever maintains the addon (Workshop tab, version roll calls, bug reports). |
| `Core.lua` | `ns.REALM_GROUP` | The author's and Treasurer's realm group. |
| `Core.lua` | `ns.TREASURER_CHARACTER`, `ns.TREASURER_MAIL_CHARACTER` | The Treasurer and the character that receives dues and treasury mail. |
| `Core.lua` | `ns.TREASURY_OFF` | `true` hides the Treasury, Dues and Bank features. |
| `Core.lua` | `ns.GUILD_NAME` | Already `"Sylvanistas"`. |
| `Core.lua` | `ns.APPROVED_BUILTIN` | Other guilds of yours whose names don't contain "Sylvanistas". |
| `UI.lua:2098`, `Versions.lua`, `Sylvanistas.toc` | links, `## Author` | Your GitHub, CurseForge, and author name, or leave them. |
| `media/*.tga` | logos, emblem | These are still the **Olympus artwork**. Replace them with your own TGA files of the same size. |

## 2. Features that need keys (off until set)

- **Signed lists**: High Council, Stewards, approved guilds and titles (`Sign.lua`, `Sign.N` / `Sign.MU`).
  The Olympus author's RSA key was removed, so every signature is refused for now. Using these
  needs your own RSA-2048 (e = 3) key and a signing script; the original `scripts/council-sign.py`
  isn't included in the addon.
- **Discord link** (`Link.lua`: `LINK_BACKEND_KEYS`, `LINK_CA_KEYS`, `LINK_SITE`): needs a Discord
  bot with an Ed25519 key. It stays "not open" until then.

Everything else works without keys: census, roster, map, layers, **layer hop**, chats (`/sy`,
`/syc`, `/syld`), decrees, Vox polls, the Board, crafters, and the Throne once `GM_CHARACTER` is set.

## 3. Things to know

- **Horde only** (`ns.FACTION_ONLY`). On Alliance characters the addon stays idle.
- **Guild matching**: any guild whose name contains "Sylvanistas", allowing one typo
  ("Silvanistas", "Sylvanystas"), plus `APPROVED_BUILTIN`. "Anti Sylvanistas" style names are excluded.
- **Seal the channel**: until an officer runs `/syl key <secret>`, anyone who joins
  `SylvanistasNetH` by name can read the census. Members get the key automatically.
- **Layer hop** only finds helpers among members running this addon. The more members who install
  it, the better it works.
- Locale text keeps the Olympus roles (King, Lords, Captains, Hands, High Council) with the name
  changed. Rename them in `Locales.lua` if you want different titles.

## 4. Install

Copy this `Sylvanistas` folder into
`/Applications/World of Warcraft/_classic_beta_/Interface/AddOns/` and `/reload`.
