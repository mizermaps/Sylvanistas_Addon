# Sylvanistas: where we left off

*Paused on 2026-10-03 at version **1.2.0**. Local copy: `~/Desktop/claude/Sylvanistas/`.
Release zip: `~/Desktop/claude/Sylvanistas-1.2.0.zip`. Repo (private): github.com/mizermaps/Sylvanistas_Addon.*

---

## 1. Open decisions
- [ ] **The guild rank named "Veteran"** shows in **The Realm → Ranks**. It's the guild's own rank
      name in WoW, so the Dark Lady renames it in game (Guild Control). Before renaming, pick one:
  - **(a)** rename to "Dark Lord" in game; those members lose the bronze border/nameplate mark (no addon change)
  - **(b)** rename to "Dark Lord" and update the bronze rule to "Raider or Dark Lord" (`Borders.lua`, `ranks = {…}`)
  - **(c)** pick a name that doesn't clash with the addon's "Dark Lord" role (e.g. Deathstalker, Revenant) and add it to the bronze rule

  Note: in the addon, "Dark Lord" is the **guild master** of each Sylvanistas guild.

## 2. CurseForge (in progress)
- [ ] Create the project. Decided so far:
  - **Name:** Sylvanistas (slug `sylvanistas`, or `sylvanistas-guild` if taken)
  - **Summary:** *Guild addon for the Horde guild Sylvanistas on WoW Forever: census and map, layer hop, one-click party gathering, guild chats and the Dark Lady's tools.*
  - **Main category:** Guild. **Additional:** Chat & Communication, Map & Minimap
  - **License:** MIT. **Distribution:** allow (so WowUp works)
  - **Visibility:** unlisted is fine (share the link)
  - **Project image:** an "S" emblem rather than the Sylvanas portrait (CurseForge's copyrighted-imagery rule). The S emblems are in the Trash or the repo history.
  - **Description and changelog:** drafted in the chat. The description's **Credits** section (credit and link to Olympus) is required.
- [ ] Upload **`Sylvanistas-1.2.0.zip`** as **Beta**. Not GitHub's "Download ZIP": its folder name is wrong.
- [ ] Once the slug exists, put the real link in the addon (placeholders `CHANGEME-sylvanistas`):
      `UI.lua` (`UI.LINKS.curseforge`) and `Versions.lua` (two fallbacks). Then release **1.2.1**.
- [ ] After a member installs from the link, check that **updates** reach them through the app (unlisted projects).

## 3. Test in game (with 2-3 characters)
- [ ] **Party invites:** `/syl party on` on alts, one with `/syl partyauto on`, all in the same zone:
  - Board → **Gather a party**
  - **Party Scream** and its **Join** button
  - **Gather the zone** past five (raid prompt)
  - Check that nobody is invited in a dungeon, in combat, or while Busy
- [ ] **Layer hop** still works alongside party auto-join
- [ ] **Bronze portrait border** (game frame tinted bronze) and the **raid-marker star** on member nameplates
- [ ] **Key rotation by a Dreadguard** (`/syl key rotate`): a guildmate's `/syl status` should switch channel
- [ ] Long grey lines now **wrap** (Board "No flags yet…", census empty line, mentor hint)
- [ ] The new **Screams tab icon** (screaming face) shows; if not, use `Spell_Shadow_DeathScream`
- [ ] If anything breaks: `/syl bug`, paste it in the next session

## 4. Guild rollout
- [ ] **Seal the channel** together: the Dark Lady and the Dreadguard agree a secret privately; one runs
      `/syl key <secret>`. If the key is lost, the first Dreadguard online re-types **the same** secret.
- [ ] Get **1.2.0** to every member (CurseForge link, or the zip). Party invites need it on everyone.
- [ ] Use the **Workshop** roll call (Riztosin) to see who has updated; right-click → **Ask to update** for the rest.
- [ ] Share **`GUIDE.md`** with the guild (e.g. Discord).

## 5. Optional, later
| Item | What it takes |
|---|---|
| **Signing** (Ambassador, moderator Dreadguard, approved guilds) | Our own signing tool (not Olympus's), with **expiry** to close the old-list replay hole; the public key goes in `Sign.lua` |
| **Treasury / Dues / Bank** | Fill `TREASURER_CHARACTER` and `TREASURER_MAIL_CHARACTER` in `Core.lua`, set `TREASURY_OFF = false` |
| **Discord Link** | A Discord bot plus Cloudflare Worker and D1, a link page on a public repo, keys; rename tags `OLC2/OLK2/OLY4/OLB5` → `SYC2/SYK2/SYL4/SYB5` in addon, Worker and page together |
| **Party text in other languages** | Party strings are English only (end of `Locales.lua`) |
| **Other tab icons** | Census and Tabards kept as they are; options were noted in chat |
| **Minimap right-click** party toggle | Offered, not built |

---

## Known limitations
- **Forever beta wipes addon data at login:** settings and privacy answers (including party invites and
  the channel key) are asked again or re-shared each session. `/syl backup` and `/syl restore` cover settings.
- **Most features work only between members running the addon:** layer hop, parties, chats, Screams,
  polls. Alone, it's a roster, census and map tool.
- **Layer hop:** needs a member on the target layer with layer help on; the Dark Lady never sends invites
  herself; layers are read from nearby NPCs.
- **Unsealed channel:** until `/syl key`, anyone who joins `SylvanistasNetH` by name can read the census.
- **Off until set up:** signed lists (Ambassador, moderator Dreadguard, approved guilds), Treasury, Discord Link.
- **Translations:** German, French and Spanish are partial; Portuguese is complete; party text is English only.
- **Not tested in game:** party invites, the bronze/star art swap, Dreadguard key rotation, line wrapping.
- **"Dark Lord" means two things** if a guild rank gets that name (see Open decisions).
- **Game AddOns copy** must be refreshed by hand: unzip the release zip into `AddOns/`, then restart the game.

---

## How to release an update
1. Make the change, then bump the version in **both** `Core.lua` (`ns.VERSION`) and `Sylvanistas.toc`
   (`## Version`), e.g. `1.2.1` for fixes or `1.3.0` for features.
2. Commit and push.
3. Build the upload zip (the folder inside must be `Sylvanistas/`):
   ```sh
   cd ~/Desktop/claude/Sylvanistas
   git archive --format=zip --prefix=Sylvanistas/ -o ../Sylvanistas-<version>.zip HEAD -- . ':(exclude)art-source' ':(exclude).gitignore'
   ```
4. Upload to CurseForge as **Beta**, with a changelog.

## Where things live
| What | Where |
|---|---|
| Guild settings (GM, author, realm, switches) | top of `Core.lua` |
| Party invites | `Party.lua` (new in 1.2.0); hooks in `Board.lua`, `Core.lua` |
| All English text | `Locales.lua` (`L.KEY = "…"` lines); help answers in `AnswerBank.lua` |
| Translations | `Locales.lua` (Portuguese), `Locales/deDE.lua`, `frFR.lua`, `esES.lua` |
| Icons and emblem | `media/` (source image in `art-source/emblem_v01.png`) |
| Player guide / overview | `GUIDE.md` / `README.md` |
| Licenses | `LICENSE.txt` (MIT, keeps the Olympus notice: required), `libs/*/LICENSE*` |
