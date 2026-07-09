# replay.gd — Records and stores a full game as a discrete state timeline.
#
# The game is fully cell-discrete (pieces move in whole cells, the board
# only changes on lock/clear), so a replay is just the sequence of visible
# states with timestamps — no re-simulation or RNG determinism needed, so
# playback is always pixel-identical to the original run.
#
# Storage is compact:
#   boards[]  — each a hex string: 220 type digits + 220 mask digits
#               (10x22 grid; type 0-7, connectivity mask 0-15 both fit a
#               hex digit). Appended only when the board actually changes.
#   frames[]  — [t, px, py, rot, ptype, hold, board_ver], appended only
#               when something visible changes.
class_name Replay
extends RefCounted

const GRID_W := 10
const GRID_H := 22

# ── Metadata (filled by finish()) ──
var mode: int = 0            # sprint target (20/40/100/200), 0 = endless
var result: String = ""      # "complete" | "topout"
var score: int = 0
var lines: int = 0
var level: int = 1
var duration: float = 0.0
var date_unix: int = 0
var new_record: bool = false

# ── Timeline ──
var boards: Array[String] = []
var frames: Array = []
# Splash ripple events (piece locks): each [t, amp, c0x,c0y, ... c3x,c3y]
# in GRID cells, so playback rebuilds pixel centers at its own cell size.
var splashes: Array = []

var _last_board: String = ""
var _last_key: String = ""


func start() -> void:
	boards.clear()
	frames.clear()
	splashes.clear()
	_last_board = ""
	_last_key = ""


func add_splash(t: float, amp: float, cells: Array) -> void:
	if cells.size() < 4:
		return
	var ev: Array = [snappedf(t, 0.001), amp]
	for k in range(4):
		ev.append(int(cells[k].x))
		ev.append(int(cells[k].y))
	splashes.append(ev)


# Frame layout: [t, px, py, rot, ptype, hold, board_ver, lines, score]
const F_T := 0
const F_PX := 1
const F_PY := 2
const F_ROT := 3
const F_PTYPE := 4
const F_HOLD := 5
const F_VER := 6
const F_LINES := 7
const F_SCORE := 8


func capture(t: float, ptype: int, px: int, py: int, rot: int, hold: int,
		board_hex: String, lines_n: int, score_n: int) -> void:
	"""Append a frame iff the visible state changed since the last capture."""
	var ver: int
	if board_hex == _last_board and not boards.is_empty():
		ver = boards.size() - 1
	else:
		boards.append(board_hex)
		_last_board = board_hex
		ver = boards.size() - 1

	var key := "%d,%d,%d,%d,%d,%d,%d,%d" % [ptype, px, py, rot, hold, ver, lines_n, score_n]
	if key == _last_key:
		return
	_last_key = key
	frames.append([snappedf(t, 0.001), px, py, rot, ptype, hold, ver, lines_n, score_n])


func finish(p_mode: int, p_result: String, p_score: int, p_lines: int,
		p_level: int, p_duration: float, p_date: int, p_new_record: bool) -> void:
	mode = p_mode
	result = p_result
	score = p_score
	lines = p_lines
	level = p_level
	duration = p_duration
	date_unix = p_date
	new_record = p_new_record


# ── Serialization (Dictionary <-> JSON-friendly) ──

func to_dict() -> Dictionary:
	return {
		"mode": mode, "result": result, "score": score, "lines": lines,
		"level": level, "duration": duration, "date": date_unix,
		"new_record": new_record, "boards": boards, "frames": frames,
		"splashes": splashes,
	}


static func from_dict(d: Dictionary) -> Replay:
	var r := Replay.new()
	r.mode = int(d.get("mode", 0))
	r.result = str(d.get("result", ""))
	r.score = int(d.get("score", 0))
	r.lines = int(d.get("lines", 0))
	r.level = int(d.get("level", 1))
	r.duration = float(d.get("duration", 0.0))
	r.date_unix = int(d.get("date", 0))
	r.new_record = bool(d.get("new_record", false))
	var b: Array[String] = []
	for s in d.get("boards", []):
		b.append(str(s))
	r.boards = b
	r.frames = d.get("frames", [])
	r.splashes = d.get("splashes", [])
	return r


# ── Board grid <-> hex string (types 0-7, masks 0-15) ──

static func encode_board(types: PackedInt32Array, masks: PackedInt32Array) -> String:
	var s := ""
	for v in types:
		s += "%x" % (v & 0xF)
	for v in masks:
		s += "%x" % (v & 0xF)
	return s


func decode_types(ver: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var hex := boards[ver]
	for i in range(GRID_W * GRID_H):
		out.append(hex.substr(i, 1).hex_to_int())
	return out


func decode_masks(ver: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var hex := boards[ver]
	var base := GRID_W * GRID_H
	for i in range(GRID_W * GRID_H):
		out.append(hex.substr(base + i, 1).hex_to_int())
	return out


# ── Playback helpers ──

func frame_at(t: float) -> Array:
	"""Latest frame whose timestamp <= t (binary search)."""
	if frames.is_empty():
		return []
	var lo := 0
	var hi := frames.size() - 1
	var best := 0
	while lo <= hi:
		var mid := (lo + hi) / 2
		if float(frames[mid][0]) <= t:
			best = mid
			lo = mid + 1
		else:
			hi = mid - 1
	return frames[best]
