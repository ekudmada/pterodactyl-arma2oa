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

# Which params file to start with (the egg's "Params File" variable), so several setups
# such as params_dayz and params_life can sit side by side in the server folder.
PARAMS=${PARAMS_FILE:-params}
PARAMS=${PARAMS//\\//}
if [[ ! -f "${PARAMS}" ]]; then
    echo "Params file '${PARAMS}' not found in the server folder."
    echo "Create it, or change Params File in the server's Startup settings."
    exit 1
fi

# Turn a path from params into a Linux path. Accepts relative, Z:\ and
# /home/container/... forms, with \ or / separators.
to_linux_path() {
    local path=${1//\\//}
    path=${path#[Zz]:}
    [[ "${path}" == /* ]] || path="/home/container/${path}"
    printf '%s' "${path}"
}

# Last value of -<name>= in the params file, without quotes.
param_value() {
    tr -d '\r' < "${PARAMS}" | grep -i "^\"\?-$1=" | tail -n 1 | cut -d= -f2- | tr -d '"'
}

# Match the ports to the server's allocation: game port, +1 Steam query, +2 Steam.
# The Steam ports go into the server config the params file uses (-config=).
sed -i -E "s/^-port=.*/-port=${SERVER_PORT}/" "${PARAMS}"
grep -q '^-port=' "${PARAMS}" || printf '\n-port=%s\n' "${SERVER_PORT}" >> "${PARAMS}"
SERVER_CFG=$(param_value config)
SERVER_CFG=$(to_linux_path "${SERVER_CFG:-server.cfg}")
if [[ -f "${SERVER_CFG}" ]]; then
    sed -i -E "s/^\s*steamQueryPort\s*=.*/steamQueryPort = $((SERVER_PORT + 1));/I" "${SERVER_CFG}"
    sed -i -E "s/^\s*steamPort\s*=.*/steamPort = $((SERVER_PORT + 2));/I" "${SERVER_CFG}"
else
    echo "WARNING: server config ${SERVER_CFG} not found, Steam ports not set."
fi
echo "Ports: game ${SERVER_PORT}/udp, Steam query $((SERVER_PORT + 1))/udp, Steam $((SERVER_PORT + 2))/udp"

# The profiles folder (RPT log, BattlEye) is set in params; default to the reference's "profiles".
if ! grep -qi '^"\?-profiles=' "${PARAMS}"; then
    [[ -n "$(tail -c 1 "${PARAMS}")" ]] && echo >> "${PARAMS}"
    echo "-profiles=profiles" >> "${PARAMS}"
fi
# Linux path of it for the console's log tails (supervisord.conf).
PROFILES_DIR=$(param_value profiles)
PROFILES_DIR=$(to_linux_path "${PROFILES_DIR:-profiles}")
export PROFILES_DIR
mkdir -p "${PROFILES_DIR}" 2>/dev/null

# Arguments for arma2oaserver.exe, shell-quoted for supervisord.conf: the params file,
# plus the options that only work on the real command line, not in the .par file.
# Arma ignores -exThreads and -malloc there, and extensions such as HiveExt find their
# folder (ini and log) from -profiles on the command line.
quote() {
    printf "'%s'" "${1//\'/\'\\\'\'}"
}
ARMA_CMDLINE="$(quote "-par=${PARAMS}")"
while IFS= read -r line; do
    ARMA_CMDLINE+=" $(quote "${line//\"/}")"
done < <(tr -d '\r' < "${PARAMS}" | grep -i -E '^"?-(profiles|exThreads|malloc)=')
export ARMA_CMDLINE

if [[ ! -f arma2oaserver.exe ]]; then
    echo "arma2oaserver.exe not found. Reinstall the server to download the game files."
    exit 1
fi

# Show what arma2oaserver.exe is launched with (see [program:arma2oaserver] in
# supervisord.conf) and the options it reads from the params file.
echo "Server command: wine arma2oaserver.exe ${ARMA_CMDLINE}"
echo "${PARAMS}:"
tr -d '\r' < "${PARAMS}" | awk 'NF {print "    " $0}'

MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "exec ${MODIFIED_STARTUP}"
