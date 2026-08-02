extends Node

const VOICE_INPUT_SCRIPT := preload("res://scripts/autoload/VoiceInputService.gd")

func _ready() -> void:
	var service := VOICE_INPUT_SCRIPT.new()
	var source := PackedFloat32Array()
	source.resize(48000)
	for index in source.size():
		source[index] = sin(float(index) * TAU * 440.0 / 48000.0) * 0.25
	var wav: PackedByteArray = service.encode_samples_for_test(source, 48000)
	var failures: Array[String] = []
	if wav.size() != 44 + 16000 * 2:
		failures.append("unexpected WAV size")
	if _ascii(wav, 0, 4) != "RIFF" or _ascii(wav, 8, 4) != "WAVE":
		failures.append("missing RIFF/WAVE header")
	if _u16(wav, 22) != 1 or _u32(wav, 24) != 16000 or _u16(wav, 34) != 16:
		failures.append("WAV format is not mono 16 kHz PCM16")
	if _u32(wav, 40) != 16000 * 2:
		failures.append("unexpected WAV data length")
	service.free()
	if failures.is_empty():
		print("VOICE_INPUT_ENCODING_CHECK passed")
		get_tree().quit(0)
		return
	for failure in failures:
		printerr("VOICE_INPUT_ENCODING_CHECK failed: " + failure)
	get_tree().quit(1)

func _ascii(bytes: PackedByteArray, offset: int, length: int) -> String:
	return bytes.slice(offset, offset + length).get_string_from_ascii()

func _u16(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)

func _u32(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8) | (int(bytes[offset + 2]) << 16) | (int(bytes[offset + 3]) << 24)
