# NIGHT SHIFT relay server container (any Docker host: Render, Fly.io, Railway, a VPS...).
# TLS is expected to be terminated by the platform (players connect with wss://).
FROM debian:bookworm-slim
ARG GODOT_VERSION=4.7.2
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget unzip \
    && wget -q https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip \
    && unzip -q Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip \
    && mv Godot_v${GODOT_VERSION}-stable_linux.x86_64 /usr/local/bin/godot \
    && rm -f *.zip && apt-get purge -y wget unzip && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY project.godot relay_main.tscn relay_server.gd ./
RUN godot --headless --path /app --import || true
ENV PORT=9080
EXPOSE 9080
CMD ["sh", "-c", "godot --headless --path /app -- --port=${PORT}"]
