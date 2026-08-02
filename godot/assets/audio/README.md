# 背景音乐

将背景音乐放在本目录，并命名为以下任意一个文件名：

- `menu_music.ogg`（推荐）
- `menu_music.mp3`
- `menu_music.wav`

主菜单会自动播放第一个找到的文件，并使用设置页中的“背景音乐”音量。其他场景也可以调用：

```gdscript
Audio.play_music("res://assets/audio/你的音乐.ogg")
Audio.set_music_paused(true)
Audio.set_music_paused(false)
Audio.set_music_loop(true)
Audio.set_music_volume(0.7)
Audio.stop_music()
```

音乐音量读取 `Settings.settings.audio.music`，取值范围为 `0.0` 到 `1.0`。

建议使用循环衔接自然的 OGG 文件。替换音乐文件后重新启动项目，Godot 会自动导入并在主菜单播放。
