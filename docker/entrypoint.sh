#!/bin/bash
# Pterodactyl entrypoint: prepares the server folder, then hands off to the
# egg's startup command (supervisord, same as the reference image).
cd /home/container || exit 1

# Wine refuses a prefix owned by another user. Pterodactyl runs containers as a
# non-root user, so each server gets its own copy of the image's prefix
# (built with dotnet462, vcrun2013 and vcrun2015). The copy is replaced whenever
# the image's prefix changes, since a prefix from another Wine version can break.
if [[ -O /wine32 ]]; then
    export WINEPREFIX=/wine32
else
    export WINEPREFIX=/home/container/.wine32
    if [[ ! -f "${WINEPREFIX}/system.reg" ]] || ! cmp -s /wine32/.prefix-id "${WINEPREFIX}/.prefix-id"; then
        echo "Copying Wine prefix to ${WINEPREFIX} (first start after an image update)..."
        rm -rf "${WINEPREFIX}"
        mkdir -p "${WINEPREFIX}"
        cp -a /wine32/. "${WINEPREFIX}/" 2>/dev/null
    fi
fi
export WINEARCH=win32

# Wine doesn't create AppData\LocalLow. Without it, Windows' certificate cache
# (cryptnet) fails while steamclient.dll connects to Steam, and the server crashes
# and exits right after "Initializing Steam server". Wine names the profile after
# the user, so cover the image's build user and whoever runs the server.
for wine_user in root container "${USER}" "$(id -un 2>/dev/null)"; do
    [[ -n "${wine_user}" ]] && mkdir -p "${WINEPREFIX}/drive_c/users/${wine_user}/AppData/LocalLow" 2>/dev/null
done
for profile in "${WINEPREFIX}"/drive_c/users/*/; do
    [[ -L "${profile%/}" ]] || mkdir -p "${profile}AppData/LocalLow" 2>/dev/null
done
export WINEDEBUG="${WINEDEBUG:--all}"
export HEADLESS_CLIENT="${HEADLESS_CLIENT:-true}"

# Pterodactyl mounts a fresh /tmp, so recreate the X11 socket folder for Xvfb.
mkdir -p /tmp/.X11-unix 2>/dev/null

# Wine keeps its shared memory in /tmp. Wings' default 100 MB tmpfs fills up while the
# server loads PBOs, which fails with "File read error: ...,ERROR_NOACCESS" and a crash.
TMP_MB=$(df -Pm /tmp 2>/dev/null | awk 'NR == 2 {print $2}')
if [[ -n "${TMP_MB}" && "${TMP_MB}" -lt 1024 ]]; then
    echo "=========================================================================="
    echo " WARNING: /tmp is only ${TMP_MB} MB. The server will likely crash while loading"
    echo " PBOs with \"File read error: ...,ERROR_NOACCESS\"."
    echo " On the node, set docker.tmpfs_size to 2048 in /etc/pterodactyl/config.yml,"
    echo " restart Wings (systemctl restart wings), then restart this server."
    echo "=========================================================================="
fi

# Match the ports to the server's allocation: game port, +1 Steam query, +2 Steam.
if [[ -f params ]]; then
    sed -i -E "s/^-port=.*/-port=${SERVER_PORT}/" params
    grep -q '^-port=' params || printf '\n-port=%s\n' "${SERVER_PORT}" >> params
fi
if [[ -f server.cfg ]]; then
    sed -i -E "s/^\s*steamQueryPort\s*=.*/steamQueryPort = $((SERVER_PORT + 1));/I" server.cfg
    sed -i -E "s/^\s*steamPort\s*=.*/steamPort = $((SERVER_PORT + 2));/I" server.cfg
fi
echo "Ports: game ${SERVER_PORT}/udp, Steam query $((SERVER_PORT + 1))/udp, Steam $((SERVER_PORT + 2))/udp"

# The profiles folder (RPT log, BattlEye) is set in params; default to the reference's "profiles".
if [[ -f params ]] && ! grep -qi '^"\?-profiles=' params; then
    [[ -n "$(tail -c 1 params)" ]] && echo >> params
    echo "-profiles=profiles" >> params
fi
# Resolve it to a Linux path for the console's log tails (supervisord.conf). Accepts
# relative, Z:\ and /home/container/... forms, with \ or / separators.
PROFILES_DIR=$(grep -i '^"\?-profiles=' params 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '\r"')
PROFILES_DIR=${PROFILES_DIR:-profiles}
PROFILES_DIR=${PROFILES_DIR//\\//}
PROFILES_DIR=${PROFILES_DIR#[Zz]:}
[[ "${PROFILES_DIR}" == /* ]] || PROFILES_DIR="/home/container/${PROFILES_DIR}"
export PROFILES_DIR
mkdir -p "${PROFILES_DIR}" 2>/dev/null

# Some options only work on the real command line, not in the .par file: Arma ignores
# -exThreads and -malloc there, and extensions such as HiveExt find their folder (ini
# and log) from -profiles on the command line. Pass those through from params too,
# shell-quoted for supervisord.conf.
ARMA_CMDLINE=""
while IFS= read -r line; do
    line=${line//\"/}
    ARMA_CMDLINE+="'${line//\'/\'\\\'\'}' "
done < <(tr -d '\r' < params 2>/dev/null | grep -i -E '^"?-(profiles|exThreads|malloc)=')
export ARMA_CMDLINE=${ARMA_CMDLINE% }

if [[ ! -f arma2oaserver.exe ]]; then
    echo "arma2oaserver.exe not found. Reinstall the server to download the game files."
    exit 1
fi

# Show what arma2oaserver.exe is launched with (see [program:arma2oaserver] in
# supervisord.conf) and the options it reads from the params file.
echo "Server command: wine arma2oaserver.exe -par=params ${ARMA_CMDLINE}"
if [[ -f params ]]; then
    echo "params:"
    tr -d '\r' < params | awk 'NF {print "    " $0}'
else
    echo "params: (file not found)"
fi

MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "exec ${MODIFIED_STARTUP}"
