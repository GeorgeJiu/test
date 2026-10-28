# 交接文档：服务器端语音转写（Life Recorder）

> 用途：交给**服务器上的 Claude Code**，继续开发服务器端的转写、说话人区分和摘要。
> 本文只覆盖服务器端；iPhone App 的情况仅作背景说明。
> 私人信息已替换为占位符：`<中转服务器IP>`、`<SSH用户>`。不要把真实 IP、令牌、密码写进仓库或聊天。

## 1. 背景

- 用户用 DJI Mic Mini 2（经蓝牙）或 iPhone 自带麦克风全天录音，iPhone App 每 60 秒切一段 AAC，经 HTTPS 上传。
- 链路：iPhone → `https://<中转服务器IP>:18765`（腾讯云中转，frps）→ frp → 内网服务器 `127.0.0.1:18765`（`receiver.py`）→ 保存原始音频。
- **硬性要求**：
  1. 转写必须在**自己的服务器上**完成，不能调用云端 API。
  2. 录音主要是**普通话**。
  3. **原始音频永久保留**，任何程序都不能删除或修改 `/srv/life-recorder/audio/` 下的文件。
  4. 两张显卡**大部分时间在跑训练**：转写默认只用 CPU，并且用 idle 优先级，不能影响训练。

## 2. 服务器环境

| 项目 | 情况 |
|---|---|
| 系统 | Ubuntu 22.04.5 LTS，系统 Python 3.10 |
| CPU / 内存 | i9-10900X（10 核 20 线程），64 GB |
| 显卡 | 2 × RTX 3080 20GB，**通常被训练占用** |
| 网络 | 在国内。GitHub release、huggingface.co、hf-mirror.com 下载慢或连不上；**ModelScope 和清华 PyPI 镜像可用** |
| 公网 | 没有公网 IP。SSH 和接收端都经 frp 中转：`ssh -p 6000 <SSH用户>@<中转服务器IP>` |
| 不要动的东西 | 用户的 miniconda；占用 `172.18.0.1:8765` 的 `group_analyzer`（用户自己的服务）；frpc 配置改动前必须备份（见第 8 节） |

frpc：`/opt/frp/frpc.toml`，systemd 服务 `frpc.service`，版本 0.54。其中已加入：

```toml
[[proxies]]
name = "life-recorder"
type = "tcp"
localIP = "127.0.0.1"
localPort = 18765
remotePort = 18765
```

## 3. 代码与仓库

- GitHub：`GeorgeJiu/test`，分支 `claude/dazzling-meitner-dfneu3`。基于开源项目 browser-use/life-recorder（MIT）改造。
- 服务器上的副本：`/opt/life-recorder-src`（用 sudo clone 的，属于 root；更新用 `sudo git -C /opt/life-recorder-src pull`）。从服务器 push 需要另外配置 GitHub 凭证。
- **只改服务器端文件（`receiver/`、`tests/`、`docs/`）不会触发 iOS 编译**；改了 `ios/` 会自动触发 GitHub Actions 编译 IPA（用户希望改 App 后直接编译）。

服务器端文件：

| 文件 | 作用 |
|---|---|
| `receiver/receiver.py` | 接收端（Python 标准库）。`POST /v1/chunks/<uuid>` 收音频，`POST /v1/markers/<uuid>` 收重点标记，`GET /health`。Bearer 令牌认证，SHA-256 校验，SQLite 去重。原有的 Whisper 转写（`--model`）没有启用 |
| `receiver/setup_linux.py` | 安装接收端：令牌、自签名证书（825 天）、配对二维码、systemd 服务 `life-recorder` |
| `receiver/transcriber.py` | **转写程序**（本文重点） |
| `receiver/setup_transcriber.py` | 安装转写：虚拟环境、模型、自检、systemd 服务 `life-recorder-transcriber` |
| `receiver/inbox_status.py` | 只读查看：片段数、转写进度、最近片段、重点标记及其所在片段和秒数 |
| `tests/test_receiver.py` | 接收端测试（13 个），运行：`python3 -m unittest tests.test_receiver` |
| `docs/vps-deploy.md` | 部署步骤（含 frp 和转写） |

## 4. 部署后的路径

| 路径 | 内容 |
|---|---|
| `/opt/life-recorder/receiver.py`、`transcriber.py` | 服务实际运行的副本（安装脚本从仓库复制过来） |
| `/opt/life-recorder/venv` | 转写专用虚拟环境（sherpa-onnx、numpy；不含 PyTorch/CUDA） |
| `/opt/life-recorder/models/silero_vad.onnx` | 语音活动检测模型 |
| `/opt/life-recorder/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/` | `model.int8.onnx`、`tokens.txt`、`test_wavs/zh.wav` |
| `/srv/life-recorder/audio/<chunk-id>.m4a` | 原始音频（**只读，永不删除**） |
| `/srv/life-recorder/inbox.sqlite3` | SQLite（WAL 模式），接收端和转写程序共用 |
| `/srv/life-recorder/transcripts/YYYY-MM-DD.md` | 每日转写（北京时间） |
| `/srv/life-recorder/receiver.token`、`receiver.crt`、`receiver.key` | 私密文件，不要读出来贴到任何地方 |

数据目录属于系统用户 `liferecorder`，权限 700/600。

## 5. 数据格式

**`chunks` 表**：`id`（UUID）、`sha256`、`device`、`started`（UTC，ISO 8601，毫秒，`Z` 结尾）、`duration`（秒）、`path`、`status`、`transcript`、`attempts`、`retry_at`、`error`、`received`。

- `status`：`pending`（待转写）→ `transcribed`（本转写程序完成）。`complete` 是原 Whisper 流程用的，现在不用；用 `transcribed` 是为了不触发原有的导出逻辑。
- `transcript`（`transcribed` 时）：JSON 数组 `[{"start": 秒, "end": 秒, "text": "..."}]`，时间相对片段开头。
- 失败：`attempts` 加 1，`retry_at` 指数退避（最长 1 小时），`error` 只记录异常类型名（不记录内容，避免泄露隐私）。

**`markers` 表**：`id`、`device`、`at`（UTC）、`note`（目前 App 不填，为空）、`received`。

**音频特征**：AAC，32 kbps，单声道。采样率跟随输入设备：蓝牙 HFP 一般 16 kHz（窄带），iPhone 内置麦克风或 USB 接收器 48 kHz。App 切片时**不丢帧**：前一片的结束紧接下一片的开始，所以连续的片段可以无缝拼接。用户手动关录音时会产生较短的片段。

## 6. 当前转写方案

- 引擎：**SenseVoice Small（int8）+ sherpa-onnx**，`language=zh`，开启 ITN（输出标点、数字）。
- 流程（`transcriber.py`）：按 `started` 取最早的 `pending` 片段 → ffmpeg 解码为 16 kHz float32 → Silero VAD 切出说话片段（静音 0.5 s 分段，单句最长 20 s）→ 逐句识别 → 写回数据库 → 重写该片段涉及的本地日期的 Markdown（⭐ 标记按时间插入）。
- 服务设置：`CPUSchedulingPolicy=idle`、`Nice=19`、`IOSchedulingClass=idle`、`MemoryMax=4G`、`CUDA_VISIBLE_DEVICES=`（空）、`PrivateNetwork=yes`、4 个线程。
- 实测（4 线程）：60 秒片段约 1.1～1.5 秒，约实时的 1/40。
- 模型来源：服务器上从 ModelScope `pengzhendong/sherpa-onnx-sense-voice-zh-en-ja-ko-yue` 下载。校验值（与官方 GitHub 原版一致）：

```
c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51  model.int8.onnx
f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc  tokens.txt
```

  该仓库没有 `test_wavs/zh.wav`（下载下来的是 JSON 错误信息），已用用户自己的一段录音转成 wav 代替，作为自检样例。

## 7. 现状与待办

**已完成并实机验证**：iPhone 录音 → 上传 → 服务器保存；断网补传；重点标记上传和定位；转写服务已安装运行。

**用户反馈：转写"效果一般"。** 先分清是**音质问题**还是**模型问题**，以下信息还在等用户提供：

1. App"最近的音频事件"里 `Recording from …, N Hz` 的设备和采样率（16000 Hz + Bluetooth 说明是窄带蓝牙通话音质）。
2. 原始录音人耳听是否清楚。
3. 主要错误类型：同音字、人名或术语、整句乱或漏、嘈杂或多人。

也可以直接在服务器上查采样率：

```bash
sudo ffprobe -v error -show_entries stream=sample_rate,bit_rate -of default=nw=1 /srv/life-recorder/audio/<片段>.m4a
```

**建议的下一步**（按优先级）：

1. **模型对比工具**（`receiver/compare_asr.py`）：同一段音频跑多个本地模型并排输出，让用户挑。候选：SenseVoice int8 / fp32、Paraformer-large 中文（sherpa-onnx 版）、FireRedASR（sherpa-onnx 支持，普通话很强但慢）。模型优先从 ModelScope 找，用官方校验值或自检核对。默认只用 CPU；要用 GPU 必须先确认显卡空闲（`nvidia-smi`），并征得用户同意。
2. **按对话拼接、第二遍转写**：把时间上首尾相接的片段拼成一段对话（间隔超过几秒就算两段对话），整段重新转写，解决句子被 60 秒边界切断的问题，结果替换第一遍的逐片段转写。第一遍保留，保证几分钟内能看到文字。
3. **说话人区分**：在拼接后的整段对话上，用 sherpa-onnx 的说话人区分（pyannote segmentation + 3D-Speaker embedding，CPU 可跑）；加声纹库，先登记用户本人的声音，标成"我"，其他人标"说话人 N"，可以起名字，跨天保持一致。
4. **纠错和每日摘要**：显卡空闲时（例如夜间）用本地大模型（如 Qwen）根据上下文修正同音字，并生成摘要和待办。要可配置、可关闭，不能占用训练时段。
5. 音质方面（属于 App 和硬件，不是服务器端）：DJI 接收器插 iPhone USB-C 可以到 48 kHz；App 码率可以从 32 kbps 提到 64 kbps。

## 8. 规则与注意事项

- **绝不删除或改写 `/srv/life-recorder/audio/`**。新功能只读音频，结果写到别的表、列或目录。
- 改数据库结构用 `CREATE TABLE IF NOT EXISTS` 或新增列，兼容正在运行的接收端；接收端和转写程序并发访问，连接要设 `timeout=30`。
- 默认不碰 GPU；不改 miniconda；不影响 `group_analyzer` 和 frpc。
- 改 `/opt/frp/frpc.toml` 前先备份，并设置自动回滚（SSH 本身走 frp，配置写错会断开连接）：
  `sudo systemd-run --on-active=180 --unit=frpc-rollback /bin/sh -c "cp /opt/frp/frpc.toml.bak /opt/frp/frpc.toml && systemctl restart frpc"`，确认正常后执行 `sudo systemctl stop frpc-rollback.timer`。
- 已有的 systemd 服务文件内容不同时，安装脚本会拒绝覆盖。要改服务参数，先给用户看差异。
- 不要读出或打印 `receiver.token` 和配对链接；不要让用户把密码、令牌、私钥发到聊天里。
- 给用户的 shell 命令一条一行，不用反斜杠续行。
- 回复用户用中文。
- 每完成一步：说明改了哪些文件、怎么测试的、结果如何、还有什么风险，不要只说"完成"。

## 9. 常用命令

接收端和转写服务的状态：

```bash
systemctl status life-recorder life-recorder-transcriber --no-pager
```

转写日志：

```bash
sudo journalctl -u life-recorder-transcriber -n 50 --no-pager
```

片段、转写进度和标记：

```bash
sudo python3 /opt/life-recorder-src/receiver/inbox_status.py --last 20
```

更新代码后重新部署接收端（参数必须和下面一致，令牌、证书和数据都会保留）：

```bash
sudo python3 /opt/life-recorder-src/receiver/setup_linux.py --address <中转服务器IP> --port 18765 --listen 127.0.0.1 --install-service
```

重新部署转写：

```bash
sudo python3 /opt/life-recorder-src/receiver/setup_transcriber.py --pip-index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

单独转写一个文件，用于测试或对比（只读，不写数据库）：

```bash
sudo /opt/life-recorder/venv/bin/python /opt/life-recorder/transcriber.py --data-dir /srv/life-recorder --model-dir /opt/life-recorder/models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17 --vad /opt/life-recorder/models/silero_vad.onnx --file /srv/life-recorder/audio/<片段>.m4a
```

运行接收端测试：

```bash
cd /opt/life-recorder-src && python3 -m unittest tests.test_receiver
```
