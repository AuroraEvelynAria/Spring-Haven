extends Node

signal recording_changed(recording: bool, duration_seconds: float)
signal input_level_changed(level: float)
signal transcription_started
signal transcription_ready(text: String, language: String)
signal transcription_failed(message: String, retryable: bool)

const CAPTURE_BUS_NAME := "SpringHavenMicrophoneCapture"
const TARGET_SAMPLE_RATE := 16000
const MIN_RECORDING_SECONDS := 0.35
const MAX_RECORDING_SECONDS := 30.0
const DRAIN_CHUNK_FRAMES := 8192
const MIN_AUDIBLE_PEAK := 0.0002

var _capture_effect: AudioEffectCapture
var _microphone_player: AudioStreamPlayer
var _recording := false
var _transcribing := false
var _auto_finish_requested := false
var _source_sample_rate := 48000
var _captured_frames := 0
var _peak_level := 0.0
var _chunks: Array[PackedFloat32Array] = []

func _process(_delta: float) -> void:
	if not _recording:
		return
	_drain_capture()
	var duration := get_recording_duration()
	recording_changed.emit(true, duration)
	input_level_changed.emit(_peak_level)
	if duration >= MAX_RECORDING_SECONDS and not _auto_finish_requested:
		_auto_finish_requested = true
		call_deferred("_finish_after_limit")

func _exit_tree() -> void:
	if is_instance_valid(_microphone_player):
		_microphone_player.stop()

func is_recording() -> bool:
	return _recording

func is_transcribing() -> bool:
	return _transcribing

func get_recording_duration() -> float:
	return float(_captured_frames) / float(maxi(1, _source_sample_rate))

func start_recording() -> Dictionary:
	if _recording:
		return {"ok": true, "recording": true}
	if _transcribing:
		return {"ok": false, "message": "上一段语音仍在转写", "retryable": true}
	var setup := _ensure_capture_chain()
	if not bool(setup.get("ok", false)):
		return setup
	_chunks.clear()
	_captured_frames = 0
	_peak_level = 0.0
	_auto_finish_requested = false
	_source_sample_rate = maxi(8000, roundi(AudioServer.get_mix_rate()))
	_capture_effect.clear_buffer()
	_microphone_player.play()
	_recording = true
	recording_changed.emit(true, 0.0)
	return {"ok": true, "recording": true}

func cancel_recording() -> void:
	if is_instance_valid(_microphone_player):
		_microphone_player.stop()
	_recording = false
	_auto_finish_requested = false
	_chunks.clear()
	_captured_frames = 0
	_peak_level = 0.0
	if is_instance_valid(_capture_effect):
		_capture_effect.clear_buffer()
	recording_changed.emit(false, 0.0)
	input_level_changed.emit(0.0)

func stop_and_transcribe(language := "zh") -> Dictionary:
	if not _recording:
		return {"ok": false, "message": "当前没有正在录制的语音", "retryable": false}
	_drain_capture()
	_recording = false
	_auto_finish_requested = false
	if is_instance_valid(_microphone_player):
		_microphone_player.stop()
	recording_changed.emit(false, get_recording_duration())
	input_level_changed.emit(0.0)
	if get_recording_duration() < MIN_RECORDING_SECONDS:
		return _fail("录音太短，请至少说半秒", false)
	if _peak_level < MIN_AUDIBLE_PEAK:
		return _fail("没有检测到清晰语音，请检查 Windows 麦克风权限和输入设备", true)
	var source_samples := _flatten_chunks()
	var wav_bytes := encode_samples_for_test(source_samples, _source_sample_rate)
	_chunks.clear()
	_captured_frames = 0
	_peak_level = 0.0
	if wav_bytes.size() < 44:
		return _fail("录音编码失败", false)
	_transcribing = true
	transcription_started.emit()
	var core := get_node_or_null("/root/CompanionCore")
	if core == null or not core.has_method("transcribe_audio"):
		_transcribing = false
		return _fail("Companion Core 客户端尚未初始化", true)
	var result: Dictionary = await core.transcribe_audio(wav_bytes, language)
	_transcribing = false
	if not bool(result.get("ok", false)):
		return _fail(
			str(result.get("message", "语音转写失败")),
			bool(result.get("retryable", true))
		)
	var data = result.get("data", {})
	if not data is Dictionary:
		return _fail("Companion Core 返回了无效转写结果", true)
	var text := str((data as Dictionary).get("text", "")).strip_edges()
	if text.is_empty():
		return _fail("没有识别到可用文字", true)
	var detected_language := str((data as Dictionary).get("language", language))
	transcription_ready.emit(text, detected_language)
	return {"ok": true, "text": text, "language": detected_language}

func encode_samples_for_test(samples: PackedFloat32Array, source_sample_rate: int) -> PackedByteArray:
	if samples.is_empty() or source_sample_rate <= 0:
		return PackedByteArray()
	var resampled := _resample_mono(samples, source_sample_rate, TARGET_SAMPLE_RATE)
	return _encode_pcm16_wav(resampled, TARGET_SAMPLE_RATE)

func _finish_after_limit() -> void:
	if _recording:
		await stop_and_transcribe()

func _ensure_capture_chain() -> Dictionary:
	var bus_index := AudioServer.get_bus_index(CAPTURE_BUS_NAME)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus_index, CAPTURE_BUS_NAME)
		AudioServer.set_bus_volume_db(bus_index, -80.0)
	if not is_instance_valid(_capture_effect):
		for effect_index in AudioServer.get_bus_effect_count(bus_index):
			var existing := AudioServer.get_bus_effect(bus_index, effect_index)
			if existing is AudioEffectCapture:
				_capture_effect = existing as AudioEffectCapture
				break
	if not is_instance_valid(_capture_effect):
		_capture_effect = AudioEffectCapture.new()
		_capture_effect.buffer_length = MAX_RECORDING_SECONDS + 2.0
		AudioServer.add_bus_effect(bus_index, _capture_effect)
	if not is_instance_valid(_microphone_player):
		_microphone_player = AudioStreamPlayer.new()
		_microphone_player.name = "MicrophoneCapturePlayer"
		_microphone_player.stream = AudioStreamMicrophone.new()
		_microphone_player.bus = CAPTURE_BUS_NAME
		add_child(_microphone_player)
	if not is_instance_valid(_capture_effect) or not is_instance_valid(_microphone_player):
		return {"ok": false, "message": "无法初始化麦克风录音链路", "retryable": true}
	return {"ok": true}

func _drain_capture() -> void:
	if not is_instance_valid(_capture_effect):
		return
	while _capture_effect.get_frames_available() > 0:
		var frame_count := mini(
			DRAIN_CHUNK_FRAMES,
			_capture_effect.get_frames_available()
		)
		var stereo_frames: PackedVector2Array = _capture_effect.get_buffer(frame_count)
		if stereo_frames.is_empty():
			break
		var mono := PackedFloat32Array()
		mono.resize(stereo_frames.size())
		for index in stereo_frames.size():
			var frame := stereo_frames[index]
			var sample := clampf((frame.x + frame.y) * 0.5, -1.0, 1.0)
			mono[index] = sample
			_peak_level = maxf(_peak_level, absf(sample))
		_chunks.append(mono)
		_captured_frames += mono.size()

func _flatten_chunks() -> PackedFloat32Array:
	var flattened := PackedFloat32Array()
	flattened.resize(_captured_frames)
	var write_index := 0
	for chunk in _chunks:
		for sample in chunk:
			if write_index >= flattened.size():
				break
			flattened[write_index] = sample
			write_index += 1
	if write_index < flattened.size():
		flattened.resize(write_index)
	return flattened

func _resample_mono(
	samples: PackedFloat32Array,
	source_rate: int,
	target_rate: int
) -> PackedFloat32Array:
	if samples.is_empty() or source_rate <= 0 or target_rate <= 0:
		return PackedFloat32Array()
	if source_rate == target_rate:
		return samples.duplicate()
	var output_count := maxi(1, floori(float(samples.size()) * float(target_rate) / float(source_rate)))
	var output := PackedFloat32Array()
	output.resize(output_count)
	var ratio := float(source_rate) / float(target_rate)
	for index in output_count:
		var source_position := float(index) * ratio
		var left := mini(samples.size() - 1, floori(source_position))
		var right := mini(samples.size() - 1, left + 1)
		var fraction := source_position - float(left)
		output[index] = lerpf(samples[left], samples[right], fraction)
	return output

func _encode_pcm16_wav(samples: PackedFloat32Array, sample_rate: int) -> PackedByteArray:
	if samples.is_empty():
		return PackedByteArray()
	var data_size := samples.size() * 2
	var wav := PackedByteArray()
	wav.resize(44 + data_size)
	_write_ascii(wav, 0, "RIFF")
	_write_u32_le(wav, 4, 36 + data_size)
	_write_ascii(wav, 8, "WAVE")
	_write_ascii(wav, 12, "fmt ")
	_write_u32_le(wav, 16, 16)
	_write_u16_le(wav, 20, 1)
	_write_u16_le(wav, 22, 1)
	_write_u32_le(wav, 24, sample_rate)
	_write_u32_le(wav, 28, sample_rate * 2)
	_write_u16_le(wav, 32, 2)
	_write_u16_le(wav, 34, 16)
	_write_ascii(wav, 36, "data")
	_write_u32_le(wav, 40, data_size)
	for index in samples.size():
		var pcm := roundi(clampf(samples[index], -1.0, 1.0) * 32767.0)
		_write_u16_le(wav, 44 + index * 2, pcm & 0xFFFF)
	return wav

func _write_ascii(bytes: PackedByteArray, offset: int, value: String) -> void:
	var encoded := value.to_ascii_buffer()
	for index in encoded.size():
		bytes[offset + index] = encoded[index]

func _write_u16_le(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = value & 0xFF
	bytes[offset + 1] = (value >> 8) & 0xFF

func _write_u32_le(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = value & 0xFF
	bytes[offset + 1] = (value >> 8) & 0xFF
	bytes[offset + 2] = (value >> 16) & 0xFF
	bytes[offset + 3] = (value >> 24) & 0xFF

func _fail(message: String, retryable: bool) -> Dictionary:
	transcription_failed.emit(message, retryable)
	return {"ok": false, "message": message, "retryable": retryable}
