# 01 · 问题

## 起点

一台带 RTX 4060 Laptop（`10de:28a0`）的笔记本，想把 nv-uefi-unlocker 跑通。

上游的流程很直接：`make-usbroot.ps1` 生成一个 FAT32 U 盘的启动根，重启进 UEFI 启动菜单，
选中它，按空格确认，事务跑完自动切回 Windows。

在这台机器上，第一次就跑不通，而且是三个完全独立的问题叠在一起。

## 障碍一：确认阶段被一个不存在的按键中止

标准 loader 在 CONFIRM 阶段的行为：

- 空格 / 回车 → 继续
- 其他任意键、或 30 秒无输入 → 中止，**零 GPU 写入**，chain 回 Windows

第二次尝试时放了一个 `i_know_what_i_am_doing.txt`（5 秒自动运行标记），理论上什么都不用按。
结果还是被中止，日志：

```
[181ms] CONFIRM: no armed marker - Space/Enter/30s confirm semantics
[181ms] keywait: CONFIRM: Printable('\u{3}') - ABORT to Windows, NOTHING was unlocked this boot
```

`\u{3}` 是 **Ctrl+C** 的码位。第二次带 armed 标记时：

```
[511ms] CONFIRM: \i_know_what_i_am_doing.txt present - ARMED: 5s countdown auto-runs, ANY key aborts
[1184ms] tx_prep: CONFIRM: key Printable('\u{3}') during the 5s armed countdown - ABORT
```

5 秒倒计时只走了 0.67 秒。而操作者**完全没有碰键盘**。

## 障碍二：Secure Boot

loader 是未签名的 EFI 应用，Secure Boot 开启时固件直接拒绝加载。

## 障碍三：不想每次插 U 盘

想把 loader 固化到本机，开机自动跑。

---

## 为什么三个问题要分开解

它们分别作用在三个不同的层次：

| 层 | 问题 | 解法方向 |
|---|---|---|
| loader 内部 | 伪按键中止 | 改源码，重新编译 |
| 固件策略 | 未签名镜像 | 让固件信任这个文件 |
| 启动链 | 从哪启动 | 把 loader 放进 ESP 并接管启动项 |

任何一个没解，整条路都走不通。所以下面三章各解一个。

---

## 环境

| 项 | 值 |
|---|---|
| 机型 | COLORFIRE MEOW R15 24 |
| CPU | AMD Ryzen 7 7435H |
| GPU | RTX 4060 Laptop，`10de:28a0`，AD107，24 SM |
| VBIOS | 95.07.41.00.bf |
| BIOS | 1.07.11COLO1（Insyde，2023-05-18） |
| OS | Windows 11 Pro for Workstations，build 26300 |
| 工具版本 | nv-uefi-unlocker v2.1.10 |
| Secure Boot | 最终状态：开启 |
| BitLocker | 未启用（这点很重要，见 04 章） |
