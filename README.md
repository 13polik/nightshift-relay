# NIGHT SHIFT relay

Tiny WebSocket relay that lets NIGHT SHIFT co-op players on different networks play together.
Players connect with `wss://<host>`; the game host creates a room (6-character code) and
friends join it. The relay only forwards packets inside a room - it has no game logic.

Run locally: `godot --headless --path . -- --port=9080`
Docker: `docker build -t nightshift-relay . && docker run -p 9080:9080 nightshift-relay`
