# 在 Ubuntu VPS 上部署接收端

目标：iPhone 录音 → HTTPS 上传 → VPS 保存原始音频。本阶段不转写，服务器不会删除任何音频。

方案：自签名证书 + 证书指纹固定（pin）。不需要域名，不需要 nginx，不占用 80/443 端口。
默认端口 `8765`，数据目录 `/srv/life-recorder`，服务名 `life-recorder`，运行用户 `liferecorder`。

下面所有命令都在 VPS 上通过 SSH 执行，每行一条。`<你的公网IP>` 换成 VPS 的公网 IP。

## 1. 部署前检查（只读，不改任何东西）

```bash
lsb_release -a
```

```bash
python3 --version
```

需要 Python 3.10 或更高（Ubuntu 22.04 及以后自带）。

```bash
sudo ss -ltnp | grep 8765
```

没有输出说明 8765 端口空闲。若已被占用，后面安装时加 `--port 其他端口`。

```bash
ls /srv/life-recorder
```

提示 "No such file or directory" 说明目录不存在，可以直接用。

## 2. 安装依赖并下载代码

```bash
sudo apt update
```

```bash
sudo apt install -y git python3 openssl qrencode
```

```bash
sudo git clone -b claude/dazzling-meitner-dfneu3 https://github.com/GeorgeJiu/test.git /opt/life-recorder-src
```

## 3. 安装并启动服务

```bash
sudo python3 /opt/life-recorder-src/receiver/setup_linux.py --address <你的公网IP> --install-service
```

脚本会：

- 生成随机令牌（token）和自签名证书（有效期 825 天），保存在 `/srv/life-recorder`，权限仅服务用户可读；
- 创建系统用户 `liferecorder`，安装 systemd 服务并开机自启；
- 做一次本机健康检查，输出 `Health check: 200 ...` 说明服务已运行；
- 在终端显示**配对二维码**。

脚本可以重复运行：已有的令牌、证书和音频都会保留；如果 `/etc/systemd/system/life-recorder.service` 已存在且内容不同，脚本会停止，不会覆盖。

**二维码和配对链接里有你的私密令牌，不要截图发给别人，也不要贴到聊天里（包括发给我）。**

## 4. 放行端口

如果启用了 ufw 防火墙（脚本会提示）：

```bash
sudo ufw allow 8765/tcp
```

如果云服务商有"安全组 / 防火墙规则"，在控制台放行 TCP 8765 入站。

在你的 Mac 上检查能否从外网访问（预期返回 `{"error": "Unauthorized"}`，说明能连上；没带令牌所以被拒绝是正常的）：

```bash
curl -k https://<你的公网IP>:8765/health
```

## 5. iPhone 配对

1. 用 iPhone 自带"相机"扫描终端里的二维码，点弹出的提示，用 Life Recorder 打开。
2. App 会自动填好服务器地址、令牌和证书指纹，并打开配对页，点"保存"。
3. 二维码在终端里显示不全时，可以把 SSH 窗口拉大，或者重新运行第 3 步的命令再显示一次。

也可以在 App 右上角"配对服务器"里手动填写：地址 `https://<你的公网IP>:8765`，令牌在 `/srv/life-recorder/receiver.token`，证书指纹为脚本输出的 `Certificate fingerprint`。

## 6. 验证上传

1. App 里开启录音，等 2～3 分钟（每 60 秒切一段）。
2. App 上传状态应显示"已安全上传，本机副本已删除"。
3. 在 VPS 上查看：

```bash
sudo python3 /opt/life-recorder-src/receiver/inbox_status.py
```

能看到片段数、总大小和最近几段的录制时间即成功。音频文件在 `/srv/life-recorder/audio/`。

断网测试：录音时打开飞行模式 3 分钟，再关闭。断网期间的片段会留在手机上，联网后自动补传；服务器对重复上传自动去重。

## 7. 日常运维

查看服务状态：

```bash
systemctl status life-recorder
```

查看最近日志：

```bash
sudo journalctl -u life-recorder -n 50
```

查看磁盘空间（60 秒 AAC 片段约 0.25 MB，每天 24 小时约 350 MB）：

```bash
df -h /srv
```

备份（先停服务保证数据库一致，备份完再启动）：

```bash
sudo systemctl stop life-recorder
```

```bash
sudo tar czf /root/life-recorder-backup.tar.gz /srv/life-recorder
```

```bash
sudo systemctl start life-recorder
```

更新代码：

```bash
sudo git -C /opt/life-recorder-src pull
```

```bash
sudo python3 /opt/life-recorder-src/receiver/setup_linux.py --address <你的公网IP> --install-service
```

## 注意事项与未验证项

- **尚未在真实 iPhone 上验证**：iOS 是否接受"公网 IP + 自签名证书 + 指纹固定"的组合。如果配对成功但一直显示"等待上传"，请告诉我，备选方案是用域名 + Let's Encrypt 证书。
- 证书 825 天后过期，到期前需要重新生成并重新配对。
- 服务器端不会删除音频（没有启用转写，`--model` 不传）。
- 手机端目前在服务器确认保存后会删除本机副本。
- 接收端只监听 IPv4。
- 令牌泄露时：删除 `/srv/life-recorder/receiver.token`，重新运行第 3 步，再重新配对。
