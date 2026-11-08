# nv-uefi-unlocker on Secure Boot

一次在 **Secure Boot 开启**的笔记本上，把 [nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker)
跑通并做成**开机自动、不插 U 盘**的完整记录。

不是新工具，是一份**实操记录 + 三个小补丁 + 部署脚本**。

---

## 结果先行

```
GPU     : NVIDIA GeForce RTX 4060 Laptop GPU (AD107, 10de:28a0, 24 SM)
状态    : 每次开机自动解锁，Secure Boot 保持开启，不需要 U 盘
bf16    : 27.20 TFLOP/s (stock) -> 40.94 TFLOP/s (unlocked)   +50%
fp16    : 26.79 -> 40.12 TFLOP/s
fp32    :  6.70 ->  6.78 TFLOP/s                              (不变)
```

`ssdiag` 判定：

```
VERDICT [ada]: UNLOCKED (override values live)
0x823xxx PLM = 0xffffffff (OPEN)   SS0 = 0x88888888   SS1 = 0x8
READOUT_1 = 0x00000000 [full speed]
```

---

## 这台机器

| 项 | 值 |
|---|---|
| 机型 | COLORFIRE MEOW R15 24（笔记本） |
| CPU | AMD Ryzen 7 7435H |
| GPU | RTX 4060 Laptop，`10de:28a0`，AD107，24 SM，8 GiB |
| VBIOS | 95.07.41.00.bf |
| 驱动 | 576.88 |
| BIOS | 1.07.11COLO1（Insyde，2023-05-18） |
| OS | Windows 11 Pro for Workstations，build 26300 |
| Secure Boot | 开启（最终状态） |

---

## 三个问题，三个解法

### 问题 1：EC 伪造的 Ctrl+C 把确认流程中止了

标准 loader 的 CONFIRM 阶段「除空格/回车外任何键都中止」。这台机器的键盘/EC 在固件阶段
会**持续发送 `0x03`（Ctrl+C）**，导致：

```
CONFIRM: key Printable('\u{3}') during the 5s armed countdown - ABORT (no GPU writes this boot)
```

两次尝试、两次中止，第二次在完全没有碰键盘的情况下依然被中止。
这与上游 issue [#110](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/110)（某台外星人
的 Z 键卡死持续发 `0x1a`）属于同一类硬件/EC 缺陷。

**解法**：改 `keywait.rs` 和 `tx_prep.rs`，在所有"按键即中止"的窗口里忽略 `0x03`。
空格/回车仍然继续，其他键仍然中止 —— 安全语义不变，只是对这一个伪按键免疫。

补丁见 [`patches/`](patches/)。

### 问题 2：Secure Boot 拒绝未签名的 EFI

loader 没有微软签名，Secure Boot 开启时会被固件直接拦下。

这台 Insyde BIOS 的 **Administrator Secure Boot** 页面提供了
`Select a UEFI file as trusted for execution`，可以直接把指定 `.efi` 加进信任列表，
**不需要清 PK、不需要自建证书链**。

> 注意：这是**按文件**加信任（很可能记录的是文件 hash）。换掉 `BOOTX64.EFI` 之后要重新加一次。

细节见 [`docs/04-secureboot.md`](docs/04-secureboot.md)。

### 问题 3：不想每次开机插 U 盘

loader 是个普通 EFI 应用，放在 ESP 里就能被固件直接启动。

但**新增 `BootXXXX` 变量被这块固件拒绝**（`SetFirmwareEnvironmentVariableEx` 返回 `err=87`，
即使 `BootOrder` 和已有项都可写）。所以改成**修改已有的 `Boot0000`**（Windows Boot Manager）
指向我们的 loader —— loader 跑完会自动 chain 回 `bootmgfw`，行为完全一致。

兜底：把原始的 Windows 启动项复制到 `Boot2001`，万一 loader 起不来，固件会跳到它正常进系统。

细节见 [`docs/05-local-boot.md`](docs/05-local-boot.md)。

---

## 开机后到底发生了什么

```
固件
 └─ Boot0000 -> \EFI\nvunlock\BOOTX64.EFI        (Secure Boot 信任的 loader)
     ├─ 5 秒倒计时（\i_know_what_i_am_doing.txt 已放置，自动运行）
     ├─ 事务：detach claim pre-flr scrub gfw layout fwsec booter verify selectors restore flr
     ├─ SELECTOR RESULT: SS0=0x88888888 SS1=0x8
     ├─ POST-FLR: verified (selectors survive AON)
     └─ chainload -> \EFI\Microsoft\Boot\bootmgfw.efi   (Windows 正常启动)
```

全程约 10 秒，不需要按键。

---

## 这个仓库里有什么

```
README.md
docs/01-problem.md        问题与背景
docs/02-diagnosis.md      诊断过程（怎么定位到 Ctrl+C 与 Secure Boot）
docs/03-patch.md          补丁说明与 diff
docs/04-secureboot.md     Secure Boot 加信任
docs/05-local-boot.md     ESP 部署 + UEFI 启动项改写
docs/06-bench.md          BF16 matmul 实测数据
patches/                  keywait.rs / tx_prep.rs 的 diff
scripts/                  ESP 部署、启动项改写/回滚、bench 脚本
```

## 这个仓库里**没有**什么

- **任何 NVIDIA 固件资产**（`fwimage_*.bin`、`gsp_boot_*.bin`、`v67-*.bin`、`booter_load_*.bin` 等）。
  这些是 NVIDIA 的版权产物，上游项目自己也不分发。请用上游的 `make-usbroot.ps1` 在你自己的机器上生成。
- 任何个人标识（用户名、分区 GUID、机器序列号）。

---

## 风险

这是一次**单机实操记录**，不是通用方案。同样的步骤在别的机器上可能：

- 那块 BIOS 没有 `Select a UEFI file as trusted` —— 就得走自签名证书 + 改 `db`，风险高得多
- 那块 EC 发的不是 `0x03` —— 补丁里要换成你实际观测到的字节
- 固件允许新建 `BootXXXX` —— 那就不用改 `Boot0000`，方案更安全

改 `Boot0000` / 改 ESP 都可能让机器起不来。**动手前先备份**（见 `scripts/`），并确认自己能进 BIOS 恢复。

解锁本身是易失的：睡眠 / RTD3 / MUX 切换会擦掉，重启才回来。

---

## 致谢

- [physicsdolphin/nv-uefi-unlocker](https://github.com/physicsdolphin/nv-uefi-unlocker) —— 全部的关键技术在那边
- issue #110 的作者，指出卡死按键这一类问题

本仓库只记录我在这台机器上踩过的坑。
