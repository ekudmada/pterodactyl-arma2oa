# The reference uses debian:stable-slim, which was bookworm (Wine 8.0) when its author
# last verified it. Trixie's Wine 10.0 fails every PBO read with ERROR_NOACCESS.
FROM debian:bookworm-slim

# Download necessary packages
RUN dpkg --add-architecture i386 && \
	apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
		ca-certificates \
		cabextract \
		net-tools \
		procps \
		supervisor \
		wget \
		wine \
		wine32 \
		xauth \
		xvfb \
		unzip && \
	apt-get clean && rm -rf /var/lib/apt/lists/*

# Download Winetricks
RUN wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O /usr/bin/winetricks && \
	chmod +x /usr/bin/winetricks

# Install dependencies
ENV WINEPREFIX=/wine32
ENV WINEARCH=win32

# Setup Wine environment (applied to /wine32, the prefix the server actually uses)
RUN W_OPT_UNATTENDED=1 xvfb-run winetricks sound=disabled windowmanagermanaged=n && \
	W_OPT_UNATTENDED=1 xvfb-run winetricks -q \
		dotnet462 \
		vcrun2013 \
		vcrun2015 \
	2>/dev/null && \
	rm -rf  ~/.cache ~/.config ~/.local /tmp/* && \
	date +%s > /wine32/.prefix-id

# Pterodactyl: server files live in /home/container and run as a non-root user
RUN useradd -m -d /home/container -s /bin/bash container
ENV USER=container HOME=/home/container

# Copy supervisord.conf and the Pterodactyl entrypoint
COPY supervisord.conf /supervisord.conf
COPY entrypoint.sh /entrypoint.sh

WORKDIR /home/container
STOPSIGNAL SIGINT

CMD ["/bin/bash", "/entrypoint.sh"]
