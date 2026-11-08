# 04 · Secure Boot

## 先看固件给不给这个口子

进 BIOS（这台是 Insyde，开机按 Del / F2），翻到 **Administrator Secure Boot** 页面，
看到的东西决定了后面的路：

```
Select a UEFI file as trusted for execution     <-- 关键
Enforce Secure Boot                      Disabled
Erase all Secure Boot Settings           Disabled
Restore Secure Boot to Factory Settings  Disabled
PK Options / KEK Options / DB Options / DBX Options / DBT Options / DBR Options
```

**有 `Select a UEFI file as trusted for execution`** 就简单了：直接把 `.efi` 文件加进信任列表，
不用动 PK/KEK，不用自建证书链。

没有这一项的话，就得走"清 PK → 进 Setup Mode → 自己签 db → 追加自定义证书 + 微软证书"，
风险高一个数量级，本文不覆盖。

> ⚠️ `Erase all Secure Boot Settings` 和 `Restore Secure Boot to Factory Settings`
> 是**操作项不是开关**，选中就立刻执行。别点。

## 操作

1. 插着那个已经能用的 FAT32 U 盘（loader 在里面）
2. BIOS → Administrator Secure Boot → **Select a UEFI file as trusted for execution**
3. 选 U 盘 → 浏览到 `\EFI\BOOT\BOOTX64.EFI` → 命名（例如 `nvunlocker`）
4. 返回，把 **Enforce Secure Boot** 改成 **Enabled**
5. F10 保存退出

改完 `UEFISecureBootEnabled` 就从 0 变 1：

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State').UEFISecureBootEnabled
# 1
```

## 为什么敢直接开

- **BitLocker 没开**。开了的话改 Secure Boot 状态会要求输入恢复密钥，必须先导出。
  这台机器的 `manage-bde -status C:` 显示 C: 未受保护。
- **Windows 自己的 `bootmgfw.efi` 有微软签名**，Enforce 之后照样能启动。
  最坏结果是"我们的 loader 被拒"，不是"系统起不来"。

## 这个信任是按什么绑的

**没能确认**，但有个观察：

固件**不通过标准 `db` 变量暴露签名数据库**。即使 Secure Boot 已经开着，
用 `GetFirmwareEnvironmentVariableEx` 读 `db` / `dbx` 仍然返回 `ERROR_ENVVAR_NOT_FOUND`（203）：

```
db           <absent>  err=203
dbx          <absent>  err=203
PK               844 bytes  attrs=0x00000027
KEK             3066 bytes  attrs=0x00000027
```

所以它很可能把 trusted-file 列表存在私有的 NVRAM 区域，**大概率是按文件哈希**。

**实际影响**：换掉 `BOOTX64.EFI` 之后，要回 BIOS 重新加一次信任。

## 验证

加完信任 + Enforce 之后启动一次 U 盘 loader，日志正常跑完事务：

```
V67 present - unlock mode
SELECTOR RESULT: SS0=0x88888888 SS1=0x8
POST-FLR: verified (selectors survive AON)
FINAL: transaction complete
```

说明这个镜像在 Secure Boot 下确实被放行了。

---

## 附带发现：ssdiag 在 Secure Boot 下的表现

`ssdiag` 会打印一条预先写好的警告：

```
PLATFORM: Secure Boot is ON - the pinned pmxdrv.sys cannot load here.
```

但实际**它加载成功了** —— 输出末尾有 `driver service removed (remove-when-done)`，
寄存器读数也完整。如果驱动真没加载，是读不出 `0x823xxx` 那些 MMIO 的。

所以看到这条警告不用慌，看末尾有没有 `driver service removed` 更准。
