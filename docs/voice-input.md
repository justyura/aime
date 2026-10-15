# 语音输入（实验，voice 分支）

轻按 **右 Shift** 开始说话，再按一次右 Shift（或回车）结束；Esc 取消。
说话时识别中的文字以标记文本（下划线）显示在光标处，结束后整段上屏；之后可直接长按 ⌥ 对刚说的话做 AI 润色 / 翻译。

## 开启

```bash
defaults write app.zool.inputmethod.aime voice.enabled -bool true
```

右 Shift 在 RIME 中应设为 `noop`（`ascii_composer/switch_key/Shift_R`），否则会与中英切换冲突。
如果同时运行 VoxBoardMac，请退出它或改掉它的热键，避免一次按键触发两次听写。

## 引擎与凭证

识别引擎移植自 VoxBoardMac（`Packages/AIMEKit/Sources/AIMEVoice`）：豆包、ElevenLabs（实时 / 整段）、
OpenAI（Realtime Whisper / 4o Transcribe）、腾讯云（实时 / 一句话）与自建 Vox。

AIME 不内置任何凭证。设置按以下顺序读取：

1. AIME 自己的键：`defaults write app.zool.inputmethod.aime voice.<键> <值>`
   （`voice.engine`、`voice.micDeviceUID`、`voice.openAIKey`、`voice.elevenLabsKey`、
   `voice.tencentAppID`、`voice.tencentSecretID`、`voice.tencentSecretKey`、`voice.volcAppKey`、`voice.volcAccessKey`）
2. VoxBoardMac 的偏好设置（`com.wentao.voxboard.mac`，可用 `voice.preferencesDomain` 改成别的域），
   即 `asrEngine`、`micDeviceUID`、`openAIKeyUser`、`elevenLabsKeyUser`、`tencent*` 等。

## 隐私

只有你按下右 Shift 后录到的音频会发送到所选的识别服务；按下时的预录音只在本机缓冲，确认是单击后才发送。
