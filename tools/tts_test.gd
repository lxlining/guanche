extends SceneTree

func _initialize() -> void:
	var voices := DisplayServer.tts_get_voices()
	print("TTS voices:", voices.size())
	for v in voices:
		print("  ", v.get("name", "?"), " | lang:", v.get("language", "?"))
	var zh := DisplayServer.tts_get_voices_for_language("zh")
	print("中文语音数:", zh.size())
	quit()
