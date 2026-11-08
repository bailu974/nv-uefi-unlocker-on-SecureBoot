# 03 · 补丁

补丁本体在 [`patches/nv-uefi-unlocker-v2.1.10-stuck-key.patch`](../patches/nv-uefi-unlocker-v2.1.10-stuck-key.patch)，
基于 **v2.1.10** 的 tag，不是 main。

## 改了什么

核心只有一句话：**在所有"按键即中止"的窗口里，忽略 `0x03`，其余的规则一条不改。**

```rust
/// Stuck-key workaround (same class as issue #110, different key): some
/// laptop ECs synthesise a Ctrl+C (0x03) during firmware boot and keep
/// re-sending it every poll.
pub fn is_ignored_stuck_key(key: &Key) -> bool {
    matches!(key, Key::Printable(c) if u16::from(*c) == 0x03)
}
```

三处调用：

1. `wait_confirm`：读到 `0x03` 就 `continue`，继续等空格/回车或超时
2. `wait_confirm_armed`：同上
3. `tx_prep::armed_confirm_with_prep`：读到 `0x03` 只打一行日志，不 Abort

**安全语义没有放宽**：

- 空格 / 回车 → 继续，和原来一样
- 其他任意键 → 中止，和原来一样
- 超时 → 中止（非 armed）或继续（armed），和原来一样
- 唯一的区别：`0x03` 不再被当成"人按了停止"

## 为什么不干脆忽略所有键

那等于把确认机制整个删掉 —— U 盘插在一台碰巧从它启动的机器上就会无人值守地跑事务。
忽略**一个特定的、已经证明是硬件噪声的字节**，才是最小改动。

## 编译

没有 MSVC 也没关系，UEFI target 用的是 Rust 自带的 `rust-lld`，只有 **build script（host 侧）**
需要链接器。两个办法：

```powershell
# 办法 A：装 Visual Studio Build Tools（重）
# 办法 B：换 GNU host toolchain（轻，本文采用）
rustup toolchain install stable-x86_64-pc-windows-gnu --profile minimal
rustup run stable-x86_64-pc-windows-gnu rustup target add x86_64-unknown-uefi

cd <repo>
cargo +stable-x86_64-pc-windows-gnu efi-tx
```

产物：`target/x86_64-unknown-uefi/release/loader.efi`

> 一定要用 `efi-tx`（带 `--features tx`），`efi` 编出来的是只读版本，没有写入路径。

## 验证产物

```
大小      : 410112 bytes（原版 410624，少 512）
PE Machine: 0x8664 (x64)
Subsystem : 0x000a (EFI application)
```

## 编译时的两个坑

### 坑 1：workspace 里的 assets / sim 缺席

只克隆了 `loader` 和 `romcore` 时，`cargo` 会抱怨 `assets` 在 `default-members` 里但不是 member。
改 `Cargo.toml`：

```toml
members = ["loader", "romcore"]
default-members = ["romcore"]
```

### 坑 2：crates.io 太慢

在仓库的 `.cargo/config.toml` 里加镜像（注意 rsproxy 的 git 索引已经 404，要用 sparse）：

```toml
[source.crates-io]
replace-with = "rsproxy-sparse"

[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
```

## 效果

修复后，同一个 5 秒倒计时窗口里：

```
[343ms]  CONFIRM: ignoring synthetic Ctrl+C (0x03) during the 5s armed countdown - stuck-key workaround
[402ms]  CONFIRM: ignoring synthetic Ctrl+C (0x03) ...
[835ms]  ...
[5135ms] CONFIRM: 5s armed countdown elapsed - PROCEED (marker file opted in)
[5338ms] TX: V67 present - unlock mode
```

**十二次**伪按键被吞掉，倒计时正常走完，事务开始。

---

## 如果换成你的机器

先别急着套这个补丁。跑一次原版，看日志里被中止时打的是什么字节：

```
CONFIRM: key Printable('\u{XX}') - ABORT
```

把 `0x03` 换成你实际看到的那个值。

如果中止的原因是超时而不是按键（日志会是 `30s timeout - ABORT`），那不是这个问题，别乱改。
