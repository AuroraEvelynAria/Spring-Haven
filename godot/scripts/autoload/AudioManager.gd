extends Node

## Background-music interface. Put a file at one of the default paths below,
## or call play_music("res://path/to/music.ogg") from any scene.

const DEFAULT_MUSIC_PATHS := [
	"res://assets/audio/menu_music.ogg",
	"res://assets/audio/menu_music.mp3",
	"res://assets/audio/menu_music.wav"
]

var _music_player: AudioStreamPlayer
var _voice_player: AudioStreamPlayer
var _current_path := ""
var _loop_enabled := true

func _ready() -> void:
	_music_player = AudioStreamPlayer.new()
	_music_player.name = "BackgroundMusic"
	add_child(_music_player)
	_music_player.finished.connect(_on_music_finished)
	_voice_player = AudioStreamPlayer.new()
	_voice_player.name = "CharacterVoice"
	add_child(_voice_player)
	apply_volume()

func play_default_music() -> bool:
	for path in DEFAULT_MUSIC_PATHS:
		if ResourceLoader.exists(path):
			return play_music(path)
	return false

func play_music(path: String, restart := false) -> bool:
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("Background music was not found: %s" % path)
		return false
	if _current_path == path and _music_player.playing and not restart:
		return true
	var stream := load(path) as AudioStream
	if stream == null:
		push_warning("Unsupported background music resource: %s" % path)
		return false
	_current_path = path
	_music_player.stream = stream
	_music_player.play()
	return true

func stop_music() -> void:
	_music_player.stop()
	_current_path = ""

func set_music_paused(paused: bool) -> void:
	_music_player.stream_paused = paused

func set_music_loop(enabled: bool) -> void:
	_loop_enabled = enabled

func set_music_volume(linear_volume: float) -> void:
	Settings.settings.audio.music = clampf(linear_volume, 0.0, 1.0)
	Settings.save()
	apply_volume()

func get_music_volume() -> float:
	return clampf(float(Settings.settings.audio.get("music", 0.7)), 0.0, 1.0)

func apply_volume() -> void:
	if not _music_player and not _voice_player:
		return
	var music_volume := get_music_volume()
	if _music_player:
		_music_player.volume_db = linear_to_db(music_volume) if music_volume > 0.0 else -80.0
	var voice_volume := clampf(float(Settings.settings.audio.get("voice", 1.0)), 0.0, 1.0)
	if _voice_player:
		_voice_player.volume_db = linear_to_db(voice_volume) if voice_volume > 0.0 else -80.0

func play_voice_bytes(audio: PackedByteArray, mime_type := "audio/wav", _role := "") -> bool:
	if audio.is_empty() or not _voice_player:
		return false
	var normalized_mime := mime_type.to_lower()
	var stream: AudioStream
	if normalized_mime.find("mpeg") >= 0 or normalized_mime.find("mp3") >= 0:
		stream = AudioStreamMP3.load_from_buffer(audio)
	elif normalized_mime.find("ogg") >= 0:
		stream = AudioStreamOggVorbis.load_from_buffer(audio)
	else:
		stream = AudioStreamWAV.load_from_buffer(audio)
	if stream == null:
		push_warning("无法解码角色语音：%s" % mime_type)
		return false
	_voice_player.stream = stream
	_voice_player.play()
	return true

func stop_voice() -> void:
	if _voice_player:
		_voice_player.stop()

func is_playing() -> bool:
	return _music_player != null and _music_player.playing

func _on_music_finished() -> void:
	if _loop_enabled and not _current_path.is_empty():
		_music_player.play()
