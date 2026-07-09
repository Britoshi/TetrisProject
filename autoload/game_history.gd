# game_history.gd — Persistent record of completed games (autoload: GameHistory).
#
# Stores each finished game (its full Replay) to user://history.json, newest
# first, capped at MAX_ENTRIES. Provides ranking/leaderboard queries derived
# from the stored games.

extends Node

signal changed

const SAVE_PATH := "user://history.json"
const MAX_ENTRIES := 40

var entries: Array = []   # Array[Dictionary], each a Replay.to_dict(), newest first


func _ready() -> void:
	_load()


func add_game(replay: Replay) -> void:
	entries.push_front(replay.to_dict())
	if entries.size() > MAX_ENTRIES:
		entries.resize(MAX_ENTRIES)
	_save()
	changed.emit()


func recent() -> Array:
	return entries


func get_replay(index: int) -> Replay:
	if index < 0 or index >= entries.size():
		return null
	return Replay.from_dict(entries[index])


# ── Rankings ──

func best_time(target: int) -> float:
	"""Fastest completed run for a sprint target, or -1 if none."""
	var best := -1.0
	for e in entries:
		if int(e.get("mode", 0)) == target and str(e.get("result", "")) == "complete":
			var t := float(e.get("duration", 0.0))
			if best < 0.0 or t < best:
				best = t
	return best


func ranked_by_time(target: int, limit: int = 10) -> Array:
	"""Completed runs for a target, fastest first. Each: {duration, date, index}."""
	var rows: Array = []
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		if int(e.get("mode", 0)) == target and str(e.get("result", "")) == "complete":
			rows.append({"duration": float(e.get("duration", 0.0)),
				"date": int(e.get("date", 0)), "index": i})
	rows.sort_custom(func(a, b): return a["duration"] < b["duration"])
	if rows.size() > limit:
		rows.resize(limit)
	return rows


func best_score() -> int:
	var best := 0
	for e in entries:
		best = maxi(best, int(e.get("score", 0)))
	return best


# ── Persistence ──

func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var data = JSON.parse_string(text)
	if data is Array:
		entries = data


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("GameHistory: could not write " + SAVE_PATH)
		return
	f.store_string(JSON.stringify(entries))
	f.close()
