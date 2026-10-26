<div align="center">

# betterRCLC

**Loot council, guild BiS lists, and raid loot management for Wrath of the Lich King.**

![WoW 3.3.5a](https://img.shields.io/badge/WoW-3.3.5a-148eff?style=flat-square)
![Interface 30300](https://img.shields.io/badge/Interface-30300-8b5cf6?style=flat-square)
![Fork of 0.5.5](https://img.shields.io/badge/Fork%20of-betterRCLC%200.5.5-f59e0b?style=flat-square)

[Download](https://github.com/meroleowl/betterRCLC/archive/refs/heads/main.zip) · [Report an issue](https://github.com/meroleowl/betterRCLC/issues)

</div>

---

> **About this fork**
>
> This project is a fork of **betterRCLC version 0.5.5**, originally created by
> **Babumbus/Valandrys**. Full credit goes to them for the original betterRCLC
> addon, built on the RCLootCouncil foundation by **Potdisc**.

## At a glance

betterRCLC brings loot decisions and guild gearing priorities together in one
addon, with tools for raiders, council members, and the master looter.

| Feature | What it does |
| --- | --- |
| **Loot council** | Review player responses, vote, and award items. |
| **Guild BiS lists** | Maintain per-spec lists and share them with the raid. |
| **Loot response cards** | See equipped gear, item-level differences, and BiS indicators when responding. |
| **Flexible imports** | Import BiS lists from WoWSims links or JSON, Discord-style text, and item links. |
| **Loot tracking** | Review loot history and keep track of items waiting to be traded. |
| **Pug tools** | Manage pug rolls and import soft reserves. |
| **Themes** | Choose a dark colour palette or follow ElvUI. |

### Added in this fork

**My wins first** — a toggle in the Council item list that moves items awarded
to you to the top. Turn it off to restore the original order.

This only changes your own view; it does not affect voting or awards. The toggle
resets when you reload the UI.

## Installation

1. **Exit WoW** and [download the latest source ZIP](https://github.com/meroleowl/betterRCLC/archive/refs/heads/main.zip).
2. Extract it and rename the `betterRCLC-main` folder to **`betterRCLC`**.
3. Place that folder inside your WoW installation's `Interface/AddOns/` directory.
4. Start WoW and enable **betterRCLC** in the character-selection AddOns menu.

Your folder structure should look like this:

```text
World of Warcraft/
└── Interface/
    └── AddOns/
        └── betterRCLC/
            ├── betterRCLC.toc
            ├── core.lua
            ├── Libs/
            └── ...
```

The required libraries are bundled. This addon targets the **3.3.5a client
(Interface 30300)**, not Retail or modern Classic clients.

## Getting started

- **Raiders:** use `/brc config` to configure the addon and `/brc specs` to check
  your main/off-spec selections. Respond to loot cards when a session starts.
- **Master looters:** configure loot rules, council members, and guild BiS lists
  before starting a raid loot session.
- **Council members:** use `/brc open` to open the main window and review the
  Council tab during a session.

### Useful commands

| Command | Action |
| --- | --- |
| `/brc` | Show help and available commands. |
| `/brc config` | Open settings. |
| `/brc open` | Open the main window. |
| `/brc specs` | Configure your main and off specs. |
| `/brc bis` | Open the BiS list editor. |
| `/brc import` | Open the BiS import window. |
| `/brc history` | View loot history. |
| `/brc winners` | View stored loot and items awaiting trade. |
| `/brc sr` | Open the soft-reserve import window. |
| `/brc pug` | Toggle the pug-roll window. |
| `/brc version` | Open the version-check module. |

`/betterrclc` is an alias for `/brc`. Loot-management actions require the
appropriate raid role; opening a window does not grant council or master-looter
permissions.

## Reporting issues

Please [open an issue](https://github.com/meroleowl/betterRCLC/issues) with:

- What you expected and what actually happened.
- Steps to reproduce the problem.
- Your addon revision.
- The exact Lua error, if one appears, and a screenshot where helpful.

Remove player information or other private details before sharing logs or
screenshots.

## Credits

- **Babumbus/Valandrys** — original author of betterRCLC; this fork is based on
  their **version 0.5.5**.
- **Potdisc** — original RCLootCouncil author.
- **Library authors and contributors** — the bundled libraries retain their
  respective attribution and licence notices.
