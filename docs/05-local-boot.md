# 05 · 本地启动（不用 U 盘）

目标：开机时固件直接跑 ESP 里的 loader，解锁完自己切回 Windows。

## 为什么资产必须摊在 ESP 根

loader 用 `get_image_file_system(image_handle())` 拿到**自己所在的那个卷**，然后从卷根读资产：

```
booter_load_ad102.bin
gsp_boot_ad102.bin
gsp_boot_desc_ad102.bin
fwimage_ad102.bin      (84 MB)
fwsignature_ad102.bin
scrubber_ad10x.bin
v67-ad102-four-plm.bin
```

不能塞进子目录，也不看别的卷。所以这 84 MB 就得摊在 ESP 根上。

这台机器 ESP 是 300 MB、空闲 264 MB，够。

```
ESP:\
  EFI\nvunlock\BOOTX64.EFI
  booter_load_ad102.bin
  ...
  i_know_what_i_am_doing.txt   <- 5 秒自动运行，不用按键
```

部署用 [`scripts/esp-deploy.ps1`](../scripts/esp-deploy.ps1)（挂载 ESP → 拷贝 → 校验 → 卸载）。

> 踩过的坑：第一次部署时源目录拿错了，拷进去的是**官方原版**（410624 字节），
> 不是改过按键的那份（410112 字节）。结果每次开机还是被 Ctrl+C 打断。
> **部署完一定要核对 SHA256。**

## 加启动项：固件不让建，但让改

理论上应该新建一个 `BootXXXX`，指向 `\EFI\nvunlock\BOOTX64.EFI`，然后塞进 `BootOrder` 最前。

实际不行。诊断结果：

| 操作 | 结果 |
|---|---|
| 读 `BootOrder` | OK |
| **写回** `BootOrder`（原值） | **OK, err=0** |
| 新建 `Boot00F0`（2 字节, attrs 0x07） | **拒绝, err=87** |
| 写回已有 `Boot2001`（原值） | OK |
| 写回已有 `Boot0000`（原值） | OK |

`87` = `ERROR_INVALID_PARAMETER`。**这块固件允许修改已有变量，但不允许创建新的 Boot 变量。**

所以改思路：**不新增，改现有的 `Boot0000`。**

`Boot0000` 是 Windows Boot Manager，原本指向 `\EFI\Microsoft\Boot\bootmgfw.efi`。
把它改成指向我们的 loader —— loader 跑完会自己 chain 回 `bootmgfw`，用户体验完全一样。

### EFI_LOAD_OPTION 长什么样

```
UINT32 Attributes            = 0x00000001 (ACTIVE)
UINT16 FilePathListLength
CHAR16 Description[]         "Windows Boot Manager\0"
EFI_DEVICE_PATH FilePathList
  ├─ HD()        42 字节，partition + start LBA + size + GPT 分区 GUID
  ├─ FilePath()  4 + 2*(len+1) 字节，UTF-16 路径
  └─ End()       4 字节  (7F FF 04 00)
UINT8 OptionalData[]         这台机器上有 136 字节，原样保留
```

关键：**HD() 节点原样保留**，只替换 FilePath()。这样不需要知道分区 GUID，
换台机器也能跑。

原来：`\EFI\Microsoft\Boot\bootmgfw.efi` → FilePath 节点 70 字节，整条 300 字节
改后：`\EFI\nvunlock\BOOTX64.EFI`        → FilePath 节点 56 字节，整条 286 字节

### 兜底

改 `Boot0000` 之前，把**原始 Windows 条目**克隆进一个已有的空槽（`Boot2001`，
原本是 `EFI USB Device` 的空壳）：

```
BootOrder: Boot0000 Boot2001 Boot2002 Boot2003
           ^loader  ^Windows(兜底)
```

万一 loader 起不来，固件试下一个 → `Boot2001` → 正常进 Windows。

### 脚本

```powershell
# 1. 备份 + 改 Boot0000 + 写兜底
.\scripts\set-boot-entry.ps1 -LoaderPath '\EFI\nvunlock\BOOTX64.EFI' -FallbackSlot Boot2001

# 2. 出问题了回滚
.\scripts\rollback-boot-entry.ps1 -AlsoRestore Boot2001
```

备份目录默认 `%ProgramData%\nv-unlock\backup`，里面是每个变量的**原始字节**。

---

## 一个 PowerShell 坑

构造 `EFI_LOAD_OPTION` 时，用数组切片拼字节：

```powershell
$hd = [byte[]]$orig[$dpStart..($dpStart + 41)]
```

**切片的返回类型是 `object[]`**，直接 `List[byte].AddRange()` 会悄悄出错，
最后拼出来的 payload 长度不对（300 字节变成 66 字节）。

正确做法是用 `MemoryStream` + `BinaryWriter` 顺序写，或者每一步都显式 `[byte[]]` 转换。

我们第一次就是这么翻的 —— 幸好固件校验长度后拒收（`err=87`），`Boot0000` 没被改坏。

**改启动项之前一定要先备份原始字节。**

---

## 最终效果

```
$ boot time 2026-11-07 23:35:59
$ Test-Path F:\      -> False          (U 盘没插)
$ SecureBoot          -> 1             (开着)
$ ESP:\loader.log     -> 65776 bytes, 23:35:56
```

```
loader::banner:  nv-uefi-unlocker v2.1.10 (built 2026-11-07 20:37:44)
CONFIRM: 5s armed countdown elapsed - PROCEED
TX: V67 present - unlock mode
SELECTOR RESULT: SS0=0x88888888 SS1=0x8
POST-FLR: verified (selectors survive AON)
FINAL: transaction complete, all DMA released
CHAIN-PRE: StartImage the preloaded '\EFI\Microsoft\Boot\bootmgfw.efi'
```

约 10 秒，全程不碰键盘。

---

## 维护提示

- **Windows 更新可能重写 `Boot0000`**，把路径改回 `bootmgfw`。那时候解锁就失效了，
  重跑一次 `set-boot-entry.ps1` 即可，文件都还在 ESP 里。
- 想彻底拆掉：`rollback-boot-entry.ps1`，然后把 ESP 根上那堆 `.bin` 和 `\EFI\nvunlock\` 删掉。
  删之前先确认启动项已经指回 Windows。
- 睡眠 / RTD3 / MUX 切换会**擦掉解锁**（只在开机时跑一次）。重启就回来。
