# bag_randomizer.gd — 7-bag piece randomizer.
# Ensures all 7 piece types appear exactly once per bag before repeating.
class_name BagRandomizer
extends RefCounted

var _queue: Array[int] = []


func _init() -> void:
	_fill_bag()


func _fill_bag() -> void:
	"""Shuffle a fresh set of 7 pieces and append to the queue."""
	var bag: Array[int] = [
		Constants.PieceType.I,
		Constants.PieceType.O,
		Constants.PieceType.T,
		Constants.PieceType.S,
		Constants.PieceType.Z,
		Constants.PieceType.J,
		Constants.PieceType.L,
	]
	bag.shuffle()
	_queue.append_array(bag)


func next_piece() -> int:
	"""Deal the next piece type and remove it from the queue."""
	if _queue.is_empty():
		_fill_bag()
	return _queue.pop_front()


func peek_next(count: int = 1) -> Array[int]:
	"""
	Look ahead at upcoming pieces without consuming them.
	Returns up to `count` piece types.
	"""
	while _queue.size() < count:
		_fill_bag()
	return _queue.slice(0, count)


func reset() -> void:
	_queue.clear()
	_fill_bag()
