#!/bin/bash
## Arma 2: Operation Arrowhead (Wine) - Pterodactyl installation script
## Install image: steamcmd/steamcmd:latest (as used by the reference README)
## Based on https://github.com/pridit-a2oa/docker-arma2oaserver-wine
##
## SteamCMD logs in with STEAM_USER / STEAM_PASS. No Steam Guard code is passed:
## if the account uses the mobile authenticator, Steam sends a push notification
## that must be approved in the Steam app while this script waits.
## Reinstall the server to update the game files.

set -o pipefail

OA_APPID=33930
A2_DIR=/mnt/server/arma2
MAX_ATTEMPTS=5

if [[ -z "${STEAM_USER}" || "${STEAM_USER}" == "anonymous" || -z "${STEAM_PASS}" ]]; then
    echo "INSTALL ERROR: A real Steam account that owns Arma 2: Operation Arrowhead is required."
    echo "              Set the Steam Username and Steam Password variables and reinstall."
    exit 1
fi

mkdir -p /mnt/server
cd /mnt/server || exit 1

#############################################################################
# Steam login (Steam Guard push notification)
#############################################################################
echo ""
echo "==========================================================================="
echo " Logging in to Steam as ${STEAM_USER}."
echo " If Steam Guard is enabled, APPROVE THE LOGIN in the Steam mobile app now."
echo " (Email-code Steam Guard is not supported; use the mobile authenticator.)"
echo "==========================================================================="
echo ""

steamcmd "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +quit | tee /tmp/steam_login.log
login_status=${PIPESTATUS[0]}
if [[ ${login_status} -ne 0 ]] || grep -qE "FAILED|Login Failure" /tmp/steam_login.log; then
    echo "INSTALL ERROR: Steam login failed (exit code ${login_status}). Check the credentials and"
    echo "              approve the Steam Guard prompt in the mobile app, then reinstall."
    exit 1
fi

#############################################################################
# Game download. Retries reuse the login SteamCMD just cached, so only one
# push notification is sent. Downloads of these packages fail intermittently.
#############################################################################
app_update() { # <install dir> <app id> [beta branch]
    local dir=$1 appid=$2 beta=$3 attempt
    for (( attempt = 1; attempt <= MAX_ATTEMPTS; attempt++ )); do
        echo "app_update ${appid} (attempt ${attempt}/${MAX_ATTEMPTS})"
        steamcmd +@sSteamCmdForcePlatformType windows +force_install_dir "${dir}" \
            "+login \"${STEAM_USER}\"" \
            +app_update "${appid}" ${beta:+-beta "${beta}"} validate +quit < /dev/null | tee /tmp/app_update.log
        grep -q "Success! App '${appid}'" /tmp/app_update.log && return 0
        sleep 5
    done
    return 1
}

# Hard-link Arma 2 content into the OA folder (Combined Operations) without doubling disk usage.
merge_dir() { # <folder name in Arma 2>
    local src dest
    src=$(find "${A2_DIR}" -maxdepth 1 -type d -iname "$1" | head -n 1)
    [[ -n "${src}" ]] || return 0
    dest=$(find /mnt/server -maxdepth 1 -type d -iname "$1" | head -n 1)
    dest=${dest:-/mnt/server/$1}
    mkdir -p "${dest}"
    echo "Merging Arma 2 $(basename "${src}") into $(basename "${dest}")"
    cp -rlf "${src}/." "${dest}/" 2>/dev/null || cp -rf "${src}/." "${dest}/"
}

app_update /mnt/server "${OA_APPID}" "${STEAM_BETA}" || {
    echo "INSTALL ERROR: Downloading Arma 2: Operation Arrowhead failed. Make sure the account owns it."
    exit 1
}

if [[ "${ARMA2_APPID}" == "33900" || "${ARMA2_APPID}" == "33910" ]]; then
    mkdir -p "${A2_DIR}"
    app_update "${A2_DIR}" "${ARMA2_APPID}" || {
        echo "INSTALL ERROR: Downloading Arma 2 (${ARMA2_APPID}) failed. Make sure the account owns that package."
        exit 1
    }
    merge_dir AddOns
    merge_dir Dta
fi

#############################################################################
# Default configs from the reference repository's .example files, only when missing
#############################################################################
if [[ ! -f params ]]; then
cat > params <<'EOF'
-server
-port=2302
-config=server.cfg
-cfg=basic.cfg
-name=default
EOF
fi

if [[ ! -f basic.cfg ]]; then
cat > basic.cfg <<'EOF'
language="English";
adapter=-1;
3D_Performance=1;
Resolution_Bpp=32;
Windowed=0;

// Bandwidth the server is guaranteed to have (in bps). This value helps server
// to estimate bandwidth available. Increasing it to too optimistic values can
// increase lag and CPU load, as too many messages will be sent but discarded.
// Default: 131072
MinBandwidth=131072;

// Bandwidth the server is guaranteed to never have. This value helps the server
// to estimate bandwidth available.
MaxBandwidth=1073741824;

// Maximum number of messages that can be sent in one simulation cycle.
// Increasing this value can decrease lag on high upload bandwidth servers.
// Default: 128
MaxMsgSend=128;

// Maximum size of guaranteed packet in bytes (without headers). Small messages
// are packed to larger frames. Guaranteed messages are used for non-repetitive
// events like shooting.
// Default: 512
MaxSizeGuaranteed=512;

// Maximum size of non-guaranteed packet in bytes (without headers).
// Non-guaranteed messages are used for repetitive updates like soldier or
// vehicle position. Increasing this value may improve bandwidth requirement,
// but it may increase lag.
// Default: 256
MaxSizeNonguaranteed=256;

// Minimal error to send updates across network. Using a smaller value can make
// units observed by binoculars or sniper rifle to move smoother.
// Default: 0.001
MinErrorToSend=0.001;

// Minimal error to send updates across network for near units. Using larger
// value can reduce traffic sent for near units. Used to control client to
// server traffic as well.
// Default: 0.01
MinErrorToSendNear=0.01;

// (bytes) Users with custom face or custom sound larger than this size are
// kicked when trying to connect.
MaxCustomFileSize=1024000;

EOF
fi

if [[ ! -f server.cfg ]]; then
cat > server.cfg <<'EOF'
/**
 * ArmA 2 OA Server Configuration
 *
 * Global settings
 */

// The name of the server that shall be displayed in the public server list.
hostname = "Arma 2 OA Server";

// Password required to connect to the server.
password = "";

// Password to protect admin access.
passwordAdmin = "changeme";

// Password required by alternate syntax of serverCommand server-side scripting.
serverCommandPassword = "changeme";

// Maximum amount of player slots.
maxPlayers = 40;

// Enables output of dedicated server console into textfile.
logFile = "server_console.log";

/**
 * Steam querying
 */

// These need to be set to ensure public visibility.
steamPort = 2304;
steamQueryPort = 2303;

/**
 * Welcome messages
 */

// Empty messages "" are used for increasing interval.
motd[] = {
    ""
};

// Time interval (in seconds) between each message.
motdInterval = 360;

/**
 * Voting behavior
 */

// Start mission-voting when X numberOfPlayers connect.
voteMissionPlayers = 1;

// Percentage of votes needed to confirm a vote.
voteThreshold = 1.50;

/**
 * Server behavior
 */

// Do not allow players with duplicate ids to connect.
kickDuplicate = 1;

// Force server into LAN mode.
loopback = 0;

// Verifies .pbos against .bisign files.
// 0 (disabled),
// 1 (prefer v2 sigs but accept v1 too).
// 2 (only v2 sigs are allowed).
verifySignatures = 2;

// Outdated. If set to 1, player has to use exactly the same -mod= startup parameter as the server.
equalModRequired = 0;

// If set to 1, Voice over Net will not be available.
disableVoN = 0;

// If set to 0 then it uses SPEEX codec.
vonCodec = 0;

// 8kHz is 0-10, 16kHz is 11-20, 32kHz (48kHz) is 21-30.
vonCodecQuality = 10;

// Missions still run on even after the last player disconnected.
persistent = 1;

// Set the timestamp format used on each report line in server-side RPT file.
// Possible values are "none" (default), "short", "full".
timeStampFormat = "full";

// Server to use BattlEye system
BattlEye = 1;

/**
 * Headless client
 */

localClient[]={"127.0.0.1"};
headlessClients[]={"127.0.0.1"};

/**
 * Scripting issues
 */

onUserConnected = "";
onUserDisconnected = "";
doubleIdDetected = "";

/**
 * Signature verification
 */

onUnsignedData = "kick (_this select 0)";
onHackedData = "kick (_this select 0)";
onDifferentData = "";

/**
 * Missions
 */

// An empty Missions class means there will be no mission rotation.
class Missions {};
EOF
fi

mkdir -p profiles/BattlEye

echo "-----------------------------------------"
echo "Installation completed"
echo "-----------------------------------------"
