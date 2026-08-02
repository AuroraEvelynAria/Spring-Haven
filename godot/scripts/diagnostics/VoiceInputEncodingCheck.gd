extends SceneTree

const VOICE_INPUT_SCRIPT := preload("res://scripts/autoload/VoiceInputService.gd")

func _initialize() -> void:
	var service := VOICE_INPUT_SCRIPT.new()
	var source := PackedFloat32Array()
	source.resize(48000)
	for index in source.size():
		source[index] = sin(float(index) * TAU * 440.0 / 48000.0) * 0.25
	var wav: PackedByteArray = service.encode_samples_for_test(source, 48000)
	_expect(wav.size() == 44 + 16000 * 2, "16 kHz 重采样后的 WAV 大小错误")
	_expect(_ascii(wav, 0, 4) == "RIFF", "缺少 RIFF 头")
	_expect(_ascii(wav, 8, 4) == "WAVE", "缺少 WAVE 头")
	_expect(_u16(wav, 22) == 1, "WAV 必须为单声道")
	_expect(_u32(wav, 24) == 16000, "WAV 采样率必须为 16 kHz")
	_expect(_u16(wav, 34) == 16, "WAV 必须为 16-bit PCM")
	_expect(_u32(wav, 40) == 16000 * 2, "WAV data 长度错误")
	service.free()
	print("VOICE_INPUT_ENCODING_CHECK passed")
	quit(0)

func _ascii(bytes: PackedByteArray, offset: int, length: int) -> String:
	return bytes.slice(offset, offset + length).get_string_from_ascii()

func _u16(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes[offset]) | (int(bytes[offset + 1]) << 8)

func _u32(bytes: PackedByteArray, offset: int) -> int:
	return (
		int(bytes[offset])
		| (int(bytes[offset + 1]) << 8)
		| (int(bytes[offset + 2]) << 16)
		| (int(bytes[offset + 3]) << 24)
	)

func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	printerr("VOICE_INPUT_ENCODING_CHECK failed: " + message)
	quit(1)
