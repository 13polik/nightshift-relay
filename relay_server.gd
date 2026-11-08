extends Node
## NIGHT SHIFT relay server - lets players on different networks play together.
##
## Every player (host and clients) connects OUT to this server over WebSocket, so no port
## forwarding or NAT traversal is needed. The server groups connections into rooms by a
## short code and forwards game packets between them; it never runs game logic (the host
## stays authoritative).
##
## Protocol
##   text  C->S {"op":"host","v":1,"room":"<optional code>","max":4}
##         C->S {"op":"join","v":1,"room":"CODE"}
##         C->S {"op":"kick","id":N}                     (host only)
##         S->C {"op":"hosted","room":"CODE","id":1}
##         S->C {"op":"joined","room":"CODE","id":N}
##         S->C {"op":"peer_connected","id":N} / {"op":"peer_disconnected","id":N}
##              (star topology: clients are only told about the host, the host about clients)
##         S->C {"op":"error","reason":"..."}
##   binary [int32 peer][u8 channel][u8 mode][payload]
##         C->S peer = target (0 all, -N all except N, N one)   S->C peer = sender
##
## Run:  godot --headless --path server/relay   (env PORT, default 9080)

const PROTOCOL := 1
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const MAX_ROOMS := 500
const MAX_PACKET := 512 * 1024
const HANDSHAKE_TIMEOUT := 10.0
const IDLE_TIMEOUT := 60.0

var server := TCPServer.new()
var port := 9080
## pending sockets awaiting their first message: [{ws, tcp, t}]
var pending: Array[Dictionary] = []
## room code -> {host: Conn, peers: {id: Conn}, max: int}
var rooms: Dictionary = {}
var rng := RandomNumberGenerator.new()
var stats := {"rooms": 0, "packets": 0, "bytes": 0}
var _report_t := 0.0


class Conn:
	var ws: WebSocketPeer
	var id: int = 0
	var room: String = ""
	var last: float = 0.0


func _ready() -> void:
	rng.randomize()
	var env_port := OS.get_environment("PORT")
	if not env_port.is_empty():
		port = int(env_port)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.substr(7))
	var err := server.listen(port, "*")
	if err != OK:
		print("RELAY ERROR cannot listen on %d: %s" % [port, error_string(err)])
		get_tree().quit(1)
		return
	print("RELAY listening on port %d (protocol %d)" % [port, PROTOCOL])


func now() -> float:
	return Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	while server.is_connection_available():
		var tcp := server.take_connection()
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = MAX_PACKET * 2
		ws.outbound_buffer_size = MAX_PACKET * 4
		ws.max_queued_packets = 4096
		if ws.accept_stream(tcp) == OK:
			var c := Conn.new()
			c.ws = ws
			c.last = now()
			pending.append({"c": c, "t": now()})
	_poll_pending()
	for code in rooms.keys():
		_poll_room(code)
	_report_t += delta
	if _report_t >= 60.0:
		_report_t = 0.0
		print("RELAY rooms=%d packets/min=%d kb/min=%d" % [rooms.size(), stats.packets, stats.bytes / 1024])
		stats.packets = 0
		stats.bytes = 0


func _poll_pending() -> void:
	for i in range(pending.size() - 1, -1, -1):
		var p: Dictionary = pending[i]
		var c: Conn = p.c
		c.ws.poll()
		var st := c.ws.get_ready_state()
		if st == WebSocketPeer.STATE_CLOSED or now() - float(p.t) > HANDSHAKE_TIMEOUT:
			c.ws.close()
			pending.remove_at(i)
			continue
		if st != WebSocketPeer.STATE_OPEN:
			continue
		while c.ws.get_available_packet_count() > 0:
			var pkt := c.ws.get_packet()
			if not c.ws.was_string_packet():
				continue
			var msg: Variant = JSON.parse_string(pkt.get_string_from_utf8())
			if not msg is Dictionary:
				continue
			pending.remove_at(i)
			_handshake(c, msg)
			break


func _handshake(c: Conn, msg: Dictionary) -> void:
	if int(msg.get("v", 0)) != PROTOCOL:
		_fail(c, "BAD_VERSION")
		return
	match str(msg.get("op", "")):
		"host":
			if rooms.size() >= MAX_ROOMS:
				_fail(c, "SERVER_FULL")
				return
			var code := str(msg.get("room", "")).to_upper().strip_edges()
			if code.is_empty():
				code = _new_code()
			elif rooms.has(code):
				_fail(c, "ROOM_TAKEN")
				return
			c.id = 1
			c.room = code
			rooms[code] = {"host": c, "peers": {1: c}, "max": clampi(int(msg.get("max", 4)), 2, 8)}
			_send(c, {"op": "hosted", "room": code, "id": 1})
			print("RELAY room %s opened" % code)
		"join":
			var code := str(msg.get("room", "")).to_upper().replace("-", "").strip_edges()
			if not rooms.has(code):
				_fail(c, "ROOM_NOT_FOUND")
				return
			var room: Dictionary = rooms[code]
			if (room.peers as Dictionary).size() >= int(room.max):
				_fail(c, "ROOM_FULL")
				return
			var id := 0
			while id <= 1 or (room.peers as Dictionary).has(id):
				id = rng.randi_range(2, 2147483647)
			c.id = id
			c.room = code
			room.peers[id] = c
			_send(c, {"op": "joined", "room": code, "id": id})
			# star topology: clients only see the host; Godot's SceneMultiplayer on the
			# host announces clients to each other itself
			_send(room.host, {"op": "peer_connected", "id": id})
			_send(c, {"op": "peer_connected", "id": 1})
			print("RELAY peer %d joined %s (%d players)" % [id, code, (room.peers as Dictionary).size()])
		_:
			_fail(c, "BAD_REQUEST")


func _poll_room(code: String) -> void:
	var room: Dictionary = rooms[code]
	var peers: Dictionary = room.peers
	for id: int in peers.keys():
		var c: Conn = peers.get(id)
		if c == null:
			continue
		c.ws.poll()
		if c.ws.get_ready_state() != WebSocketPeer.STATE_OPEN or now() - c.last > IDLE_TIMEOUT:
			_drop(code, id)
			if not rooms.has(code):
				return
			continue
		while c.ws.get_available_packet_count() > 0:
			var pkt := c.ws.get_packet()
			c.last = now()
			if c.ws.was_string_packet():
				_control(code, c, pkt.get_string_from_utf8())
				continue
			if pkt.size() < 6 or pkt.size() > MAX_PACKET:
				continue
			_forward(room, c, pkt)


func _control(code: String, c: Conn, text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if not msg is Dictionary:
		return
	match str(msg.get("op", "")):
		"kick":
			if c.id == 1:
				_drop(code, int(msg.get("id", 0)))
		"ping":
			_send(c, {"op": "pong", "t": msg.get("t", 0)})


func _forward(room: Dictionary, src: Conn, pkt: PackedByteArray) -> void:
	var target := pkt.decode_s32(0)
	pkt.encode_s32(0, src.id)
	stats.packets += 1
	stats.bytes += pkt.size()
	var peers: Dictionary = room.peers
	if target > 0:
		var dst: Conn = peers.get(target)
		if dst:
			dst.ws.send(pkt)
		return
	for id: int in peers:
		if id == src.id or (target < 0 and id == -target):
			continue
		(peers[id] as Conn).ws.send(pkt)


func _drop(code: String, id: int) -> void:
	if not rooms.has(code):
		return
	var room: Dictionary = rooms[code]
	var c: Conn = room.peers.get(id)
	if c == null:
		return
	room.peers.erase(id)
	c.ws.close()
	if id == 1:
		# host gone: the room cannot continue (no host migration)
		for other: Conn in (room.peers as Dictionary).values():
			_send(other, {"op": "peer_disconnected", "id": 1})
			other.ws.close(1000, "host left")
		rooms.erase(code)
		print("RELAY room %s closed (host left)" % code)
		return
	_send(room.host, {"op": "peer_disconnected", "id": id})
	print("RELAY peer %d left %s" % [id, code])


func _send(c: Conn, msg: Dictionary) -> void:
	c.ws.send_text(JSON.stringify(msg))


func _fail(c: Conn, reason: String) -> void:
	_send(c, {"op": "error", "reason": reason})
	c.ws.poll()
	c.ws.close(4000, reason)


func _new_code() -> String:
	while true:
		var s := ""
		for i in 6:
			s += CODE_ALPHABET[rng.randi_range(0, CODE_ALPHABET.length() - 1)]
		if not rooms.has(s):
			return s
	return ""
