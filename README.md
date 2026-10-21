# Arma 2: Operation Arrowhead Server for Pterodactyl (Wine)

A [Pterodactyl](https://pterodactyl.io/) egg and Docker image for running an **Arma 2: Operation Arrowhead** dedicated server using the Windows build (`arma2oaserver.exe`) under [Wine](https://www.winehq.org/).

## Credit

This is an adaptation of **[pridit-a2oa/docker-arma2oaserver-wine](https://github.com/pridit-a2oa/docker-arma2oaserver-wine)**. The image, Wine prefix, `supervisord` setup and default configuration files are taken from that repository; this project only adds what Pterodactyl needs to run it. All credit for the original setup goes to its author (which in turn credits [adamharley/torch-docker](https://github.com/adamharley/torch-docker)).

## What's in this repository

| Path | Purpose |
| --- | --- |
| `egg-arma2oa-wine.json` | Pterodactyl egg to import into the panel |
| `install.sh` | Readable copy of the egg's installation script (embedded in the egg) |
| `docker/Dockerfile` | Runtime image, mirrors the original Dockerfile |
| `docker/supervisord.conf` | Process setup, mirrors the original `supervisord.conf` |
| `docker/entrypoint.sh` | Pterodactyl entrypoint that prepares the server folder and starts `supervisord` |
| `.github/workflows/docker.yml` | Builds `docker/` and publishes it to `ghcr.io/ekudmada/pterodactyl-arma2oa` |

## Changes from the original for Pterodactyl

The runtime setup is kept the same as the original: Debian's packaged Wine, a 32-bit prefix at `/wine32` containing `dotnet462`, `vcrun2013` and `vcrun2015`, two Xvfb displays, the server started with `-par=params`, and the local `ArmA2OA.exe -client` connecting back to it. The differences are:

- **Debian version.** The image is pinned to `debian:bookworm-slim` (Wine 8.0). The original uses `debian:stable-slim`, which was bookworm when its author last verified it. The current stable (trixie) ships Wine 10.0, which the original was never tested with.
- **Game download.** The egg's installer runs in `debian:stable-slim`, downloads SteamCMD and installs the game plus the Steamworks SDK Redist (app 1007: `steamclient.dll`, `tier0_s.dll`, `vstdlib_s.dll`, which the server needs without a Steam client) into the server folder, instead of using a pre-filled Docker volume. The original README's `steamcmd/steamcmd` image can't be used as a Pterodactyl install container because its entrypoint is `steamcmd`.
- **Steam login.** The installer logs in with a username and password only. If the account uses the Steam Guard mobile authenticator, approve the push notification in the Steam app while the install runs. Email-code Steam Guard is not supported.
- **Server folder.** The game lives directly in `/home/container` (the Pterodactyl server folder) rather than `/arma2oa/steamapps/common/Arma 2 Operation Arrowhead`.
- **Non-root Wine prefix.** Pterodactyl runs containers as a non-root user and Wine refuses a prefix owned by someone else, so each server copies `/wine32` into its own `.wine32` folder (about 1 GB) on first start, and again whenever an image update changes the prefix.
- **Ports.** On every start, `-port=` in the params file and `steamQueryPort` / `steamPort` in the server config it names with `-config=` (default `server.cfg`) are set from the server's allocation.
- **Launch options in one file.** All options, including `-profiles`, are set in `params`. If `params` has no `-profiles=` line, `-profiles=profiles` is added on start, and the console follows whichever folder `params` names. Options that only work on the real command line (`-profiles`, `-exThreads`, `-malloc`) are copied from `params` onto the command line too: Arma ignores `-exThreads` and `-malloc` in a `.par` file, and server extensions such as Epoch's HiveExt can read `-profiles` from the command line to find their config and log folder.
- **Console.** `supervisord` sends the server's output to the panel console, and extra programs stream `server_console.log` (so the panel can detect when the server is online) and `arma2oaserver.RPT` from the profiles folder (lines prefixed with `[RPT]`) into the console.
- **Winetricks settings.** `sound=disabled` and `windowmanagermanaged=n` are applied to `/wine32`. In the original they run before `WINEPREFIX` is set, so they apply to a different prefix.
- **Wine user profile.** On every start, `AppData\LocalLow` is created in the Wine user profiles. Wine doesn't create it, and without it Windows' certificate cache fails while `steamclient.dll` connects to Steam, which crashes the server right after `Initializing Steam server`.
- **Debug output.** `WINEDEBUG=-all` is set to keep Wine's debug messages out of the console.
- **Combined Operations.** Optionally downloads Arma 2 and hard-links its `AddOns` and `Dta` folders into the OA folder, as the original's "Shared Content" section describes.

## Requirements

- A Pterodactyl panel and Wings node (x86_64)
- A Steam account that owns Arma 2: Operation Arrowhead (and Arma 2 for Combined Operations), with the Steam Guard mobile authenticator if Steam Guard is enabled
- 15 GB of disk for OA only, about 25 GB with Arma 2 content
- Three consecutive UDP ports per server
- Wings configured with a larger `/tmp` (`docker.tmpfs_size`, see below)

## Setup

### Before you start: raise Wings' /tmp size

Wings gives every server container a 100 MB `/tmp` by default. Wine keeps its shared memory there, and Arma fills it while loading PBOs, so the server crashes on startup with `File read error: ...,ERROR_NOACCESS`. On each node, set `tmpfs_size` under `docker:` in `/etc/pterodactyl/config.yml`:

```yaml
docker:
  tmpfs_size: 2048
```

Then restart Wings with `systemctl restart wings`. The setting applies to every server on the node, but a tmpfs only uses RAM for what is actually stored in it. The server prints a warning in its console on start if `/tmp` is smaller than 1 GB.

### 1. Import the egg

In the panel, go to **Admin → Nests**, create or choose a nest, click **Import Egg** and upload `egg-arma2oa-wine.json`. The egg uses the image `ghcr.io/ekudmada/pterodactyl-arma2oa:latest`.

### 2. Add allocations

Under **Admin → Nodes → your node → Allocation**, add three consecutive ports, for example `2302`, `2303` and `2304`:

| Port | Use |
| --- | --- |
| Primary allocation (e.g. 2302) | Game |
| Primary + 1 (e.g. 2303) | Steam query |
| Primary + 2 (e.g. 2304) | Steam |

Open them for UDP in the node's firewall.

### 3. Create the server

Under **Admin → Servers → Create New**, choose the egg, set the primary allocation and add the other two as additional allocations. Give it at least 4 GB of memory and enough disk (see [Requirements](#requirements)).

| Variable | Description |
| --- | --- |
| Steam Username | Steam account that owns the game |
| Steam Password | Password for that account (no Steam Guard code) |
| Arma 2 Content (Combined Operations) | `0` for OA only, `33900` for Arma 2 bought on Steam, `33910` for Arma 2 (RoW) |
| Steam Beta Branch | Optional SteamCMD beta branch for OA (app 33930) |
| Params File | Launch parameters file to start with, default `params`. See [Switching between setups](#switching-between-setups) |
| Headless Client | `true` to run the local `ArmA2OA.exe -client` like the original, `false` to disable it |

### 4. Approve the Steam login

Open the server console as soon as it's created. When the install prints **APPROVE THE LOGIN**, accept the request in the Steam mobile app. The download then runs, retrying up to 5 times if SteamCMD fails partway. The install is done when the console shows `Installation completed`.

### 5. Configure

Edit the files in the panel's file manager, the same way as in the original repository:

| File | Contents |
| --- | --- |
| `server.cfg` | Hostname, passwords, max players, missions. `steamPort` and `steamQueryPort` are overwritten on start. |
| `basic.cfg` | Network and performance settings |
| `params` | Launch parameters, one per line. Add mods here, e.g. `-mod=@CBA_CO;@ACE`. `-port=` is overwritten on start; `-profiles=` sets the profiles folder (default `profiles`). |
| `MPMissions/` | Mission `.pbo` files |
| `Expansion/Keys/` | Mod `.bikey` files |
| `profiles/BattlEye/beserver.cfg` | RCON, e.g. `RConPassword CHANGEME` |

If you set a server `password`, set **Headless Client** to `false`: the local client connects without a password and will fail to join.

### 6. Start

The first start copies the Wine prefix, which takes a minute or two. The panel marks the server online when the console shows `Host identity created`. With an empty `class Missions`, log in as admin in game (`#login <passwordAdmin>`) and choose a mission with `#missions`.

## Switching between setups

To keep several setups on one server, for example DayZ Epoch and a Life mission such as Takistan Life, give each its own params file in the server folder, such as `params_dayz` and `params_life`. Each can point to its own server config, mods and profiles folder:

```
-server
-port=2302
-config=Life_Server_Config\server.cfg
-cfg=Life_Server_Config\basic.cfg
-profiles=Life_Server_Config
-name=server
-mod=@Life_Server
```

To switch, change **Params File** in the server's **Startup** tab and restart the server. On start, the server sets `-port=` in the chosen file and the Steam ports in the config it names with `-config=`, so every setup gets the right ports. Note that the Steam ports are only written if that config has `steamPort` and `steamQueryPort` lines, and the console only shows Arma's console output if the config sets `logFile = "server_console.log";`.

## Updating the game

Stop the server and use **Settings → Reinstall Server**, then approve the Steam push notification again. Reinstalling keeps `server.cfg`, `basic.cfg`, `params`, missions and profiles.

## Building the image

GitHub Actions builds `docker/` and publishes `ghcr.io/ekudmada/pterodactyl-arma2oa:latest` whenever `docker/` changes on `main`. You can also start it manually from the **Actions** tab. The package must be set to **Public** for Wings to pull it without credentials.

To build it on a node instead (about 15 minutes):

```bash
cd docker
docker build -t ghcr.io/ekudmada/pterodactyl-arma2oa:latest .
```

Wings falls back to a local image with the same name if the pull fails.

The original Dockerfile downloads the latest Winetricks at build time, so rebuilds aren't guaranteed to be identical. Every build is also tagged with its commit (`sha-xxxxxxx`) if you need to go back to an earlier image.

## Troubleshooting

- **Full server log:** `arma2oaserver.RPT` in the profiles folder (`profiles/` by default).
- **`arma2oaserver.exe not found`:** the install didn't finish. Reinstall the server.
- **Steam login fails:** check the credentials, reinstall, and approve the push notification promptly.
- **Image pull fails:** make sure the GHCR package is public, or build the image on the node.
- **`File read error: ...,ERROR_NOACCESS` on startup:** `/tmp` is too small. See [Before you start](#before-you-start-raise-wings-tmp-size).
- **Server keeps restarting:** try setting Headless Client to `false`.
- **Editing scripts on Windows:** files in `docker/` and `*.sh` must keep LF line endings. `.gitattributes` enforces this for git checkouts.
