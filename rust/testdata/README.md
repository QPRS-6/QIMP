# 测试样本

给 Rust 侧测试用的**极小**真实音频文件（各 1 秒、单声道、16kHz、440Hz 正弦）。
刻意不用大文件：样本进版本库，体积必须小到可以忽略。

| 文件 | 内容 | 为什么需要它 |
| --- | --- | --- |
| `ogg_vorbis.ogg` | Ogg Vorbis | 常规的 `.ogg` |
| `ogg_opus.ogg` | Ogg **Opus** | 手机录音、不少下载源的 `.ogg` 其实是 Opus：曾经既播不了（symphonia 本体没有 Opus 解码器），列表里还显示 `--:--`（lofty 只看扩展名，把 `.ogg` 当 Vorbis 解析、整份失败）。这两个坑都靠这个样本钉住 |

重新生成（需要带 `libvorbis` / `libopus` 的 ffmpeg）：

```bash
bash rust/testdata/generate.sh
```
