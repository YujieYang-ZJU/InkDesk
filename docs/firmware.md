# reTerminal E1001 固件

[ESP-IDF](../ESP-IDF) 是 InkDesk 的配套固件：从 Mac 获取已渲染画面，校验后通过 SPI 刷新 E1001，并将按键操作同步回 Mac。适用于 ESP32-S3 / UC8179 / 800×480 黑白屏；Seeed 出厂固件不会自动连接 InkDesk。

固件采用常驻唤醒与轮询，建议 USB 供电。当前未实现深度睡眠、电池电量检测、OTA、SD 卡或厂商云服务。

## 硬件与工具

- Seeed reTerminal E1001、USB 数据线，以及稳定供电。
- 可访问 Mac 的 2.4 GHz Wi-Fi；设备与 Mac 所在网络需要互通。
- 已安装并激活的 ESP-IDF 环境；当前验证版本为 6.0.1。
- 在 Mac 构建并启动 InkDesk，开启设备同步服务。

公开工程默认 Flash 为 8 MB，并启用 OPI PSRAM。构建前确认设备实际 Flash 容量与 PSRAM 配置，在 `menuconfig` 中按硬件修改；不要照抄其他设备的容量。

Seeed 的 [Setup520 配置](https://github.com/Seeed-Studio/Seeed_GFX/blob/0dfdd7135425be82b5bb4b4b58d74dd51ab29a59/User_Setups/Setup520_Seeed_reTerminal_E1001.h) 选择 UC8179、800×480 和下列引脚。本驱动的全屏黑白初始化、双数据面、刷新及休眠命令来自同一提交的 [UC8179_Init.h](https://github.com/Seeed-Studio/Seeed_GFX/blob/0dfdd7135425be82b5bb4b4b58d74dd51ab29a59/TFT_Drivers/UC8179_Init.h) 与 [UC8179_Defines.h](https://github.com/Seeed-Studio/Seeed_GFX/blob/0dfdd7135425be82b5bb4b4b58d74dd51ab29a59/TFT_Drivers/UC8179_Defines.h)。驱动使用面板 OTP 黑白波形，来源声明保留在 [NOTICE-Seeed-GFX.txt](../ESP-IDF/NOTICE-Seeed-GFX.txt)。

| 功能 | 默认 GPIO | 说明 |
|---|---:|---|
| EPD SCLK | 7 | SPI 时钟 |
| EPD MOSI | 9 | SPI 数据 |
| EPD CS | 10 | 片选 |
| EPD DC | 11 | 数据 / 命令 |
| EPD RESET | 12 | 屏幕复位 |
| EPD BUSY | 13 | 低电平表示忙 |
| 左键 KEY2 | 5 | 低有效 |
| 中键 KEY1 | 4 | 低有效 |
| 右侧绿色键 KEY0 | 3 | 低有效 |

按键布局见 [Seeed 外设教程](https://wiki.seeedstudio.com/reterminal_e10xx_with_arduino_peripherals/)，OPI PSRAM 设置见 [Seeed 屏幕教程](https://wiki.seeedstudio.com/reterminal_e10xx_with_arduino/)。引脚、BUSY 极性、SPI 频率及 BUSY 超时可在 `menuconfig` 修改；启动时检查 GPIO 有效性和重复占用。默认 SPI 频率为 10 MHz，BUSY 超时为 60 秒。

## 配对与编译

1. 在 InkDesk 的“设备”页面启动同步服务。
2. 记录 App 显示的 Mac 局域网地址、端口和**设备配对密钥**。地址必须能从设备访问；`localhost` 和 `127.0.0.1` 不能用于连接另一台电脑。
3. 激活自己安装的 ESP-IDF 环境，从 InkDesk 仓库根目录进入固件工程：

```sh
# 先运行自己 ESP-IDF 安装目录中的 export.sh，或使用 ESP-IDF 终端
cd ESP-IDF
idf.py --version
idf.py set-target esp32s3
idf.py menuconfig
```

在 `InkDesk E1001` 菜单填写：

| 配置项 | 填写内容 |
|---|---|
| `2.4 GHz Wi-Fi SSID` | 自己的 Wi-Fi 名称 |
| `Wi-Fi password` | 对应密码 |
| `Mac server origin` | App 显示的地址，例如 `http://192.168.1.100:8765`；末尾不要加 `/` |
| `InkDesk device token` | App 的设备配对密钥，不能使用 AI API Key |

App 默认端口为 8765，以实际界面值为准；请覆盖固件配置中的示例地址。在 `Serial flasher config` 中选择实际 Flash 容量，并检查 PSRAM 与屏幕引脚配置。保存后构建：

```sh
idf.py build
```

默认 Wi-Fi 和设备密钥为空，必须填写自己的配置才能同步。本仓库不提供预配对固件；本地生成的空凭据固件只能作为构建参考，不能替代上述配置步骤。

Wi-Fi、服务器地址和设备密钥写入本地 `sdkconfig` 及编译产物，均不应提交到 Git 或公开分享。更换 Wi-Fi、Mac 地址、端口或配对密钥后，需要重新构建并烧录。AI API Key 仅由 Mac 持有，E1001 不需要 AI SDK。

当前连接使用 HTTP Bearer token，token、画面和任务数据以明文传输。请只在可信局域网运行，不要将 Mac 服务端口暴露到公网。若 macOS 防火墙询问是否允许 InkDesk 接收连接，按自己的网络环境设置。

## 烧录与首次检查

初次完整烧录会替换设备现有应用与分区表，并初始化帧缓存文件系统。需要保留原厂固件时，应先准备可恢复的备份。确认串口、电源和 Flash 容量后再执行；`PORT` 替换为系统识别的实际串口。

```sh
idf.py -p PORT flash monitor
```

完整烧录包含 bootloader、partition table、应用和 `cache.bin`。之后更新本项目固件时，如果分区布局保持不变，可以只烧录应用，保留帧缓存及 NVS 中尚未同步的操作：

```sh
idf.py -p PORT app-flash monitor
```

UART 日志默认使用 UART0、115200 波特率，TX GPIO43 / RX GPIO44。串口名称随系统和连接方式变化；没有日志时，检查所选串口、电源与 boot/reset 状态。不要在屏幕刷新期间断电。

首次连接后，在 App 点击“立即同步”，检查设备日志与同步状态：

1. Wi-Fi 已连接，Mac 服务可访问，认证成功。
2. 收到完整且校验通过的帧，屏幕显示方向与黑白颜色正确。
3. 驱动完成刷新后，App 显示“已确认显示”。
4. 重启设备可恢复最近有效缓存；按键可以切换页面、选择任务与同步完成状态。

首次成功回执之前，App 的显示状态应为“未确认”。“已确认”依据固件的驱动完成回执，不代表 App 对物理屏幕进行了光学检查。

## 按键操作

| 状态 | 左键短按 | 中键短按 | 右绿色键短按 | 中键长按并松开 |
|---|---|---|---|---|
| 页面模式 | 上一页 | 请求刷新 | 下一页 | 进入任务模式 |
| 任务模式 | 上一任务 | 切换所选任务完成状态 | 下一任务 | 退出任务模式 |

中键长按约 0.9 秒，动作在松开时产生；进入任务模式时聚焦第一项或上次焦点。右绿色键长按并松开可请求刷新。按键消抖约 60 ms，刷新期间仍在后台读取按键；全屏墨水屏刷新需要时间，显示不会像 LCD 一样即时更新。

任务模式的 `TASK n` 角标表示本地选中任务序号，连接正常时 Mac 画面也显示焦点。右下角的 `SYNC n` 表示待同步操作数量，覆盖区域为 96×16 像素，布局时可为其预留空间。

断网时继续显示最近有效画面。已缓存任务列表仍可选择任务并记录切换意图；操作写入 Flash 后显示 `SYNC n`，任务完成标记以 Mac 返回的新帧为准。协议没有任务行坐标，固件不会猜测位置或自行绘制完成标记。

离线切页会记录一次页面导航，等待新页面同步后再接受后续操作。固件保存最近完整帧与上一份有效快照，不提供所有页面的离线图库。最多排队 24 个事件，队列满时拒绝新操作并在串口说明；重连后按顺序重试原 eventID。

**恢复操作：同时按住三个键 5 秒后松开，丢弃尚未同步的操作。** 可用于旧页面或已删除任务导致事件持续被拒绝的情况；它不会在 Mac 上完成任务。串口记录丢弃结果，NVS 提交失败时保留原队列。

## 画面与事件协议

除 `/health` 外，设备请求都需要 `Authorization: Bearer <device-token>`。默认请求超时为 8 秒；网络失败按 2、4、8、16、32、64 秒退避。正常轮询读取 manifest 的 `pollSeconds`，固件限制为 10–3600 秒。内容未变化时跳过屏幕刷新。

App 连续编辑只保留最新一张待同步画面；设备领取后，本次传输的画面和任务元数据固定不变。App 最多保留一个待同步和一个正在传输的画面。取消待同步不影响已领取画面，刷新回执完成后才领取下一张。

| 接口 | 用途 |
|---|---|
| `GET /health` | 无需认证的服务健康检查 |
| `GET /api/sync/manifest` | 领取固定画面及任务、焦点、传输标识 |
| `GET /api/sync/frame.bin` | 下载本次领取的位图 |
| `POST /api/sync/status` | 报告下载、刷新、显示成功或失败 |
| `POST /api/action` | 提交持久化按键事件 |

manifest 校验协议版本 1、800×480、每行 100 字节、`mono1-msb-white1` 格式、UUID、SHA-256、`transferID` 与固定帧路径。位图必须恰好 48,000 字节，行优先、每字节最高位对应最左像素，1 为白色、0 为黑色。SHA-256 对原始位图计算。下载后再次读取 manifest，前后 transferID / pageID / revision / hash 不一致则丢弃画面。

刷新状态包含 transferID、pageID、revision、hash 和 state（`downloaded`、`refreshing`、`displayed`、`failed`）。只有屏幕驱动完成刷新才发送 `displayed`，App 严格匹配本次传输；HTTP 200 的回执确认须包含同一 transferID。成功显示后立即检查下一张画面。

独立 NVS 日志保存刷新回执，网络失败或响应丢失时重试原回执。已完成的相同回执可重复确认，避免仅因确认丢失而重复刷新。HTTP 409/410 表示旧传输过期或不匹配，此时清除旧回执后重新领取，保留像素与按键操作；400 或认证失败继续保留回执。读取缓存不能证明屏幕完成刷新，重启后仍须在驱动完成后报告成功。App 将 180 秒未完成的领取视为过期，保留最新待同步画面以便重试。

按键事件包含 eventID、action、pageID，以及需要时的 taskID。先写 NVS 再发送，只有 HTTP 200 且 `ok: true` 才删除。响应丢失或重启后重放原 eventID，Mac 持久化去重，避免同一任务被切换两次。

App 保留旧 `/api/manifest`、`/api/frame.bin` 和 `/api/frame.png` 接口用于兼容旧客户端；这些接口没有刷新成功确认，新版 E1001 使用上述同步接口。

UC8179 驱动在发送 `0x10` 与 `0x13` 数据面前转换像素极性，用于白底黑字显示。转换包含状态角标，发生在帧校验之后；缓存与 Mac 原始帧保持白色位 1 格式。

协议上限为 24 个页面、96 个可操作任务和 64 KiB manifest。超出限制时拒绝画面，不显示部分内容。

## 持久化与故障排查

Flash 使用 64 KiB NVS 保存操作队列及独立刷新回执日志，2 MiB SPIFFS 保存两个完整帧快照。快照包含元数据、生成序号和原始位图；启动检查摘要与帧 SHA-256，选择最新有效快照。写入中断时可以回退上一份完整快照，但电源故障情形仍需更多硬件验证。状态角标不写入帧缓存，也不改变原始 hash。

启动不会自动擦除 NVS，也不会自动格式化损坏缓存。`cache.bin` 用于首次文件系统初始化；重写空缓存镜像会丢失本地画面，但不清除 NVS 操作队列。NVS 无法打开时禁用操作记录，避免把未持久化的任务切换误报为已接受。

| 现象 | 检查方向 |
|---|---|
| 找不到 Mac | 服务是否启动、地址和端口是否正确、Mac 是否休眠、防火墙与 Wi-Fi 客户端隔离 |
| HTTP 401 / 403 | 设备配对密钥是否一致，是否误用了 AI API Key |
| 事件 HTTP 409 / 422 | 目标页面已改变，或任务已删除 / 不在当前页面；确认后再决定是否丢弃旧操作 |
| 等待重试 | 传输租约可能过期；检查连接与日志，App 点击重试 |
| 屏幕无更新或 BUSY 超时 | 检查供电、型号、引脚、BUSY 极性和 Flash / PSRAM 配置 |
| 缓存不可挂载 | 检查分区布局与首次烧录是否完整，再决定是否重新初始化缓存 |

## 测试与限制

从固件工程目录运行无需硬件的主机测试：

```sh
./tests/run_host_tests.sh
```

测试覆盖 manifest / UUID / action / 队列验证，以及 SHA-256 和帧校验；测试脚本启用 AddressSanitizer 与 UndefinedBehaviorSanitizer。ESP-IDF 6.0.1 的 ESP32-S3 构建和 E1001 的联网、刷新、缓存恢复及按键任务同步已有验证，仍应在自己的设备上完成首次检查。

温度范围、长期刷新、多页连续操作、网络响应丢失、电源故障和 BUSY 超时恢复需更多实机测试。电池部署还需要增加睡眠策略和功耗验证。

项目采用 [MIT License](../LICENSE)；第三方来源见 [Seeed_GFX 声明](../ESP-IDF/NOTICE-Seeed-GFX.txt) 与 [cJSON 许可证](../ESP-IDF/main/vendor/LICENSE.cJSON)。
