# Sylvanistas

A guild addon for the Horde guild **<Sylvanistas>** on WoW: Forever (Classic beta).
Census and roster, the map, **layer detection and layer hop**, guild chats, the Dark Lady's
Sanctum, Screams, polls and more. Main command: **`/syl`**.

## Install
Copy the `Sylvanistas` folder into `World of Warcraft/_classic_beta_/Interface/AddOns/` and
restart the game. It runs on Horde characters in a guild whose name contains "Sylvanistas";
anywhere else it stays idle.

## Settings (`Core.lua`, top)
| Setting | Value |
|---|---|
| `ns.GUILD_NAME` | `Sylvanistas` |
| `ns.GM_CHARACTER` / `ns.GM_REALM` | `Testiana Paladina` / `ClassicBetaPvE` (the Dark Lady) |
| `ns.GM_DISPLAY` | `Dark Lady` |
| `ns.AUTHOR_CHARACTER` | `Riztosin Psalmpalm` (Workshop tab, roll calls, bug reports) |
| `ns.TREASURER_CHARACTER`, `ns.TREASURER_MAIL_CHARACTER` | `CHANGEME_…` (no treasurer yet) |
| `ns.TREASURY_OFF` | `true` (Treasury, Dues and Bank hidden) |
| `ns.WALL_OF_SHAME` | `false` (the untabarded list stays private) |

A `CHANGEME_` name can belong to no real character, so that role stays empty until it is set.

## Roles and terms
| Term | Who / what |
|---|---|
| **the Dark Lady** | the guild master |
| **Ambassador** | her deputy (signed list) |
| **Dark Rangers** | helpers she names in game |
| **Dreadguard** | officers (rank 0-1), and the moderators (signed list) |
| **Dark Lords** | guild masters of Sylvanistas guilds |
| **the Forsaken** | everyone |
| **Sanctum** | the Dark Lady's tab |
| **Screams** | map calls: **Banshee Scream** (hers), **Call for the Revenant** (help needed), **Gathering** (meeting point) |
| **Edicts**, **Audience**, **Absolution**, **Portal**, **Voice of the Forsaken** | her letters, audiences, clearing a name, recruiting pin, polls |

## Commands
| Command | What it does |
|---|---|
| `/syl` | open the window |
| `/syl status` | what the addon detects (guild, channel, layer) |
| `/syl privacy` | sharing switches (layer, layer help, chats…) |
| `/syl hop` | ask for an invite to another layer |
| `/sy`, `/syd`, `/sydl` | chats: everyone, Dreadguard, Dark Lords |
| `/syl screams`, `/syl rise`, `/syl gather` | screams; Call for the Revenant; Gathering |
| `/syl voice` | polls |
| `/syl key <secret>` | seal the guild channel (Dreadguard) |
| `/syl key rotate` | new channel key nobody sees (the Dark Lady or a Dreadguard) |
| `/syl backup`, `/syl restore` | save and restore settings as text |
| `/syl bug` | copyable error report |

## Limits
- **Layer hop** works between members running the addon who said yes to layer help; the Dark
  Lady never sends invites herself. Layers are read from nearby NPCs.
- **Seal the channel** with `/syl key` once several Dreadguards hold the same secret: until then
  anyone who joins `SylvanistasNetH` by name can read the census.
- **Signed lists** (Ambassadors, moderator Dreadguards, approved guilds) and **Discord Link** need
  keys and are off; every signature is refused until a public key is set in `Sign.lua`.
- The Forever beta wipes addon data at login: settings and privacy answers come back each session.
- Translations: German, French and Spanish cover part of the text (the rest shows in English);
  Portuguese is complete.

## Using it
See **GUIDE.md**: a step-by-step guide for every rank, from the Dark Lady to the Forsaken.

## Credits and licenses
- Sylvanistas by SwiftyPigeon512, released under the MIT license (`LICENSE.txt`), which also
  carries the notice of the MIT-licensed addon it is derived from.
- Libraries, each under its own license: HereBeDragons (BSD, `libs/HereBeDragons/LICENSE.txt`),
  CallbackHandler-1.0 (BSD, `libs/CallbackHandler-1.0/LICENSE-Ace3.txt`), LibStub (public domain),
  QREncode (BSD, notice in `libs/QREncode/qrencode.lua`).
