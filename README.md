# Sixes Hub

Personal media-maintenance hub: a hidden PowerShell GUI for managing app shortcuts and one-click system updates.

## Open it

Double-click `Open Sixes Hub.cmd`. It launches `SixesHub_MediaMaintenance_patched_v6_4_2_ui.ps1` with `-WindowStyle Hidden` so the window can't be accidentally closed.

## Update all apps

Double-click `UpdateAll.cmd` (asks for admin). It runs:

1. `winget upgrade --all`
2. Checks for Chocolatey; offers to install it if missing
3. `choco upgrade all -y` (if Chocolatey present)

## Install SpotX (Spotify mod)

Double-click `scripts/Install-SpotX.ps1`. Pulls and runs the official SpotX installer from the `SpotX-Official/SpotX` repo main branch.

## Configuration

- `config.json` — your personal state (window title, app list, winget exclusions). **Not tracked in git** — edit it freely.
- `config.example.json` — committed template. Copy it to `config.json` if you lose yours.

## Prerequisites

- Windows 10/11 with [winget](https://aka.ms/getwinget)
- Chocolatey (optional — `UpdateAll.cmd` can install it for you)
