# TotemManager

Live totem cards for [Azeroth Survivors](https://wow.aethus.pl/). One card per totem: how many stand, how long until each one dies, the damage the totem is dealing right now, a fill status bar, and a plain verdict on whether that totem is still worth spending upgrades on.

## What each card shows

- **Totem name and icon**
- **Total** - totems standing right now out of the game's cap, with a small trend dot beside it: green when the count is climbing, red when it is dropping, yellow when it is steady
- **Next Death** - seconds until the totem runs out
- **Duration** - how long one totem lives once placed
- **DPS** - the damage the totem type is dealing right now, sampled from the game's damage meter four times a second and smoothed over about 2 seconds, abbreviated (600, 1.5k, 10k, 100k, 1.5M)
- **Fill Status** - a bar with the average fill: how much of the cap that totem type holds on average over its lifetime. While history is still short the bar is solid blue and reads "Calculating". After that: red under 40%, yellow under 70%, green under 99%, purple at 99% or more, with the percentage inside
- **Verdict** - a line in a larger font: **Upgrade Needed** (colored like the bar) or **Cap Reached** (purple)

Cards sit side by side and stay sorted alphabetically, so they never swap places in the middle of a run. Hover a card to open the spell's own tooltip. The addon judges only how many totems stand, never their damage.

## Install

1. Get the addon: a release zip when there is one, or GitHub's **Download ZIP**.
2. In game, open **Options > AddOns > Open AddOns Folder** (Windows and Linux), or install the zip through **Options > AddOns** (browser).
3. The path must end in `AddOns/AZTotemManager/AZTotemManager.toc`. GitHub's source archive unpacks as `AZTotemManager-main` with the addon folder inside it, and the game will not load that name. Rename the folder to `AZTotemManager`, or move the folder inside it up into AddOns.
4. Relog, or type `/reload`. Addons load when the world loads.

## Use

| Command |  |
| --- | --- |
| `/tw` | Open or close the settings |
| `/tw reset` | Put the frame back at its original spot |
| `/tw dump` | Print every `AZS_` global to the chat frame (diagnostics) |
| `/totemmanager` | Same as `/tw` |

- Right click a card or the frame to open settings. Drag any card to move the whole frame.
- Settings: show or hide the verdict, the remaining time and duration, the trend dot, auto hide when no totems are up, lock the position, and set where the yellow band starts (70% by default).
- The frame position is remembered between sessions.

## How the verdict works

Every 0.25 seconds the addon notes how many of each totem type stand on the ground. It averages that count over one totem lifetime (the Duration rounded up to the next 5 seconds, kept between 15 and 120) and compares the average to the cap: that is the fill percentage. While history has not yet covered one full window the bar says Calculating (about 25 to 30 seconds for the usual totems). The verdict reads **Cap Reached** when the average sits at the cap: more upgrades for that totem would change nothing. It reads **Upgrade Needed** when there is still room. The number judged is always the count of totems standing: damage shows separately on the DPS line.

## Requirements

- A current Azeroth Survivors build: the totem list, clock, and damage meter come from the game's `AZS` API.

## Notes

- Settings save in `AZTotemManagerDB`; a fresh install starts with the defaults.
- The "Upgrades" and "Your bonuses" numbers shown on spell tooltips are built inside the game and are not exposed to addons. Hover a totem card to read them.
- Any effect the game reports through its totem list gets a card of its own, so the addon is not limited to Shaman totems.
