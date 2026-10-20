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
export WINEDEBUG="${WINEDEBUG:--all}"
export HEADLESS_CLIENT="${HEADLESS_CLIENT:-true}"

# Pterodactyl mounts a fresh /tmp, so recreate the X11 socket folder for Xvfb.
mkdir -p /tmp/.X11-unix 2>/dev/null

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

if [[ ! -f arma2oaserver.exe ]]; then
    echo "arma2oaserver.exe not found. Reinstall the server to download the game files."
    exit 1
fi

MODIFIED_STARTUP=$(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')
echo ":/home/container$ ${MODIFIED_STARTUP}"
eval "exec ${MODIFIED_STARTUP}"
