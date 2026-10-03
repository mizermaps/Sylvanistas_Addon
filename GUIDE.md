# Sylvanistas: how to use it, from the Dark Lady to the Forsaken

Start with **Part 1** whatever your rank, then read your own part.

| Your place in <Sylvanistas> | Read |
|---|---|
| Everyone | [Part 1: Getting started](#part-1-getting-started-everyone) and [Part 2: The Forsaken](#part-2-the-forsaken-every-member) |
| Officers (guild ranks 0 and 1) | + [Part 3: Dreadguard](#part-3-dreadguard-officers) |
| Helpers the Dark Lady names | + [Part 4: Dark Rangers](#part-4-dark-rangers) |
| The guild master (Testiana Paladina) | + [Part 5: The Dark Lady](#part-5-the-dark-lady-guild-master) |
| The addon keeper (Riztosin Psalmpalm) | + [Part 6: The addon keeper](#part-6-the-addon-keeper) |

> **Who is who in the addon:** the **Dark Lady** is the guild master. **Dreadguard** are the
> officers (guild ranks 0 and 1). **Dark Rangers** are helpers she names in the addon. A
> **Veteran** is the guild master of a Sylvanistas guild (with one guild, that is the Dark Lady).
> **The Forsaken** are everyone. The addon gives powers by **rank position**, not rank name.

---

## Part 1: Getting started (everyone)

1. **Install.** Copy the `Sylvanistas` folder into
   `World of Warcraft/_classic_beta_/Interface/AddOns/`, then **restart the game** (not just `/reload`).
2. **Log in** on your Horde character in <Sylvanistas>. On any other character the addon stays idle.
3. **Answer the privacy page.** It opens by itself after login (or type `/syl privacy`).
   Each line stays **off until you say Yes**. For layer hop, say **Yes** to:
   - **Share my zone and layer**
   - **Layer help** (lets others ask you for an invite to your layer)
   - **Chats**, if you want the guild chats
4. **Open the window:** type `/syl` or click the minimap button.
5. **Check it works:** `/syl status`. You should see your guild, the channel, and your layer
   once you have looked at an NPC.

> **The beta forgets addon settings at login.** If the privacy page comes back, answer it again.
> `/syl backup` copies your settings as text; `/syl restore` pastes them back.

---

## Part 2: The Forsaken (every member)

### Layer hop
- **Join the Dark Lady's layer:** go to her zone, then click **Ask invite** in the window, or type `/syl hop`.
- **Join any other layer:** open the **Realm** tab, find the layer in the layers list, and **click it**.
- **What happens:** a member on that layer gets your request and invites you, the game moves you
  to their layer, and the addon takes you out of the group.
- **Help others:** keep **layer help** on (`/syl layerhelp on`). `/syl layerauto on` invites
  without asking each time.
- Your layer is read from nearby NPCs: **target or mouse over an NPC** if the addon doesn't know it yet.

### Chat
| Type | To |
|---|---|
| `/sy <text>` | every Sylvanistas member with the addon |
| `/sy` alone | opens the **Chat** tab |
| `/syl mute sylvanistas` | hides that channel from your chat window |

These chats are **not private**: never type passwords or secrets there.

### Screams (map calls)
Officers and the Dark Lady send **Screams**. You'll see a message, hear a sound and see a map marker:
- **Call for the Revenant:** someone needs help here (an elite, a rare, a quest boss). Lasts 5 minutes.
- **Gathering:** meet here (dungeon run, raid, guild event). Lasts 30 minutes.
- **Banshee Scream:** an announcement from the Dark Lady or the Dreadguard.

All current Screams are on the **Screams** tab (`/syl screams`).

### When the Dark Lady asks something
- **Voice of the Forsaken** (polls): a window pops up, so tick your answer. Prefer chat only? `/syl voice off`.
- **Audience:** when she holds an audience, a line appears if you're in her zone. Click it to ask to speak with her.
- **Summon the Veterans:** a roll call for Veterans and Dreadguards; answer **Present, my Lady** or **Busy**.
- **Edicts:** her formal letters. Click **As you command** to acknowledge.

### Groups, crafting and more
| Want to… | Do |
|---|---|
| Find a group | `/syl lfg dungeon` (or `raid`, `layer`) raises your flag on the **Board**; `/syl lfg off` lowers it |
| See the guild's week | `/syl week` (events, and signups for them) |
| Find a crafter | `/syl craft <item>` |
| List your professions | open a profession, then `/syl crafter on` |
| Link your alts | `/syl alt add <name>`, then log the alt and confirm |
| See loot notes | `/syl loot` |
| Ask the moderators for help | `/syl helpme <question>` |

### Quiet and privacy
| Want to… | Do |
|---|---|
| Silence alert sounds | `/syl sound off` (or one kind: `/syl sound rise off`) |
| Hold alerts in dungeons | on by default (`/syl alerts quiet`) |
| Ignore a player | `/syl block <name>` |
| Hide lines with a word | `/syl filter add <word>` |
| Change what you share | `/syl privacy` |

### Something's wrong?
1. `/syl status` shows what the addon sees.
2. `/syl bug` gives a report to copy. Paste it to the addon keeper, or in a comment on the CurseForge page.

---

## Part 3: Dreadguard (officers)

Officers are guild **ranks 0 and 1**. Everything in Part 2, plus:

### Seal the guild channel (do this once, together)
Until it's sealed, anyone who joins the hidden channel by name can read the census.
1. Agree on **one secret** (6+ characters) with the Dark Lady and the other Dreadguard, **privately**.
2. One of you types `/syl key <secret>`.
3. Members online move at once; others get the key at login **from any Dreadguard who is online**.
4. Check with `/syl status`: it should say **channel sealed**.
5. If the key is lost (everyone logged off) or `/syl status` says **public**, the first Dreadguard
   online types `/syl key <the same secret>`. **The same secret, or the guild splits in two.**

**If the key leaks:** `/syl key rotate` makes a new key nobody sees and moves the guild to it.

### Send Screams
| Scream | How |
|---|---|
| **Call for the Revenant** | `/syl rise <note>` or the button on the **Screams** tab |
| **Gathering** | `/syl gather <note>` or the button on the **Screams** tab |
| **Banshee Scream** | the button on the **Screams** tab (the Dark Lady and the Dreadguard) |
| Preview only you see | add `test`: `/syl rise test` |

### Officers' chat and tools
| Want to… | Do |
|---|---|
| Talk to officers and Veterans | `/syd <text>` (Dreadguard channel) |
| See who's been away | `/syl inactive 7` (or 14, 30). Removing someone takes a confirm, one per click. |
| Check a player's gear | target them in range, `/syl gear` |
| Write loot notes and points | **Realm** tab, loot notes (`/syl loot`) |
| Answer recruits | a recruit's request shows **Invite** and **Decline** buttons |

---

## Part 4: Dark Rangers

The Dark Lady names you on her **Sanctum** tab. You then see the **Sanctum** tab and can, for her:

| Tool | Where |
|---|---|
| **Summon Veterans** (roll call) | **The Realm** tab |
| **Voice of the Forsaken** (polls) | **Voice of the Forsaken** tab |
| **Agenda** (events on the guild's week) | **Agenda** button on the **Sanctum**, e.g. `Sat 20:00 Raid night` |
| **Banshee Inspection** (tabard check) | **Tabards** tab |
| **Portal** (pins a guild on top for recruits, 2 hours) | **Realm** tab, recruiting |
| **Pin a line** for every member, 2 hours | `/syl pin <text>`; `/syl pin off` |
| **Hide a player** from all addon screens | `/syl netoff <name>: <reason>`; `/syl neton <name>` |

---

## Part 5: The Dark Lady (guild master)

Everything above, plus tools only she has. Her character is **Testiana Paladina**; the addon
calls her **Dark Lady** and puts her **crown** on the map.

### First steps
1. **Seal the channel** with the Dreadguard (Part 3).
2. **Name your Dark Rangers:** **Sanctum** tab → **Dark Rangers**.
3. **Show your crown** on the map (the **Sanctum** tab), so members can find you and hop to your layer.
   On your layer and not in a group? The addon may offer to **invite people who want to join your layer**:
   say yes to let it handle that.

### Her tools
| Tool | What it does |
|---|---|
| **Hold Audience** (**Sanctum**) | members in your zone queue to speak with you; you call them one by one |
| **Edicts** | formal letters to the Veterans, the Dreadguard or everyone, signed by you |
| **Voice of the Forsaken** | quick polls, 2 to 6 answers |
| **Agenda / the week** | dated events with signups (raid night, etc.) |
| **Banshee Scream** | a free-text announcement shown to every member |
| **Banshee Inspection** | members who opted in check tabards around them for 2 minutes |
| **Absolution** | clears a name from your untabarded list for a week |
| **Portal** | sends new recruits to a guild for 2 hours |
| **Key rotation** | **Sanctum** (or `/syl key rotate`): a new channel key nobody sees |

The **untabarded list** stays yours alone; there is no Wall of Shame.

---

## Part 6: The addon keeper

Riztosin Psalmpalm has the **Workshop** tab:
- **Roll call:** which versions members run, and what errors they hit.
- **Please update:** a fixed reminder sent to a player on an old version.
- **Bug reports:** members can send theirs to you in game while you're online.

**Releasing an update:** change the version in `Core.lua` (`ns.VERSION`) and in `Sylvanistas.toc`
together, using plain rising numbers (e.g. `1.1.3`).

---

## Not switched on yet
| Feature | Why |
|---|---|
| **Ambassador** (the Dark Lady's deputy) and **moderator Dreadguard** | appointed by a signed list, which needs a signing key |
| **Treasury, Dues, Bank** | no treasurer yet (`ns.TREASURY_OFF = true` in `Core.lua`) |
| **Discord Link** | needs a Discord bot |

## Quick reference
| Command | Who | What |
|---|---|---|
| `/syl` | all | open the window |
| `/syl status` | all | what the addon sees |
| `/syl privacy` | all | sharing switches |
| `/syl hop` | all | ask for an invite to the Dark Lady's layer |
| `/syl layerhelp on` | all | let others ask you for invites |
| `/sy` / `/syd` / `/syv` | all / Dreadguard / Veterans | chats |
| `/syl screams` | all | the Screams tab |
| `/syl voice on/off` | all | polls in a window, or in chat only |
| `/syl lfg …` | all | the Board |
| `/syl rise`, `/syl gather` | Dreadguard | Call for the Revenant, Gathering |
| `/syl key <secret>` | Dreadguard | seal the channel |
| `/syl key rotate` | Dreadguard, Dark Lady | new channel key |
| `/syl pin <text>` | Dark Lady, Dark Rangers | pin a line for 2 hours |
| `/syl bug` | all | copy a bug report |
| `/syl help` | all | every command, in chat |
