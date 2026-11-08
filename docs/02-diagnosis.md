# 02 · 诊断

## 「它说我按了 Ctrl+C，但我没按」

第一次失败后，直觉是"是不是我按错了"。但日志里的字符是 `\u{3}`，不是空格也不是回车 ——
一个人想确认的话不会去按 Ctrl+C。

第二次换成 armed 模式（`i_know_what_i_am_doing.txt`），逻辑上是"5 秒后自动跑，任何键取消"。
结果 0.67 秒就被中止，操作者双手离开键盘。

**两次都是同一个字节 `0x03`，两次间隔很短的轮询里。**

结论：这不是人为输入。

## 怎么确认是硬件/EC 在发

几个观察点：

1. 中止发生在 PCI 枚举过程中（日志第 92 行夹在 `PCI 0000:00:18.7` 之后），
   说明 loader 在 tx_prep 阶段**每个 tick 都轮询键盘**，而某个 tick 读到了键。
2. 两次尝试都是同一个字节，不是随机噪声。
3. Windows 下键盘工作完全正常。

这是典型的 **EC 在固件阶段向 UEFI 输入队列灌入伪扫描码**。

## 上游已有同类案例

搜索 issue 标题，找到
[#110 「Alienware m18 R1: UEFI 2.00x success + stuck Z key aborts CONFIRM」](https://github.com/physicsdolphin/nv-uefi-unlocker/issues/110)。

那台外星人的 Z 键卡死，持续发 `0x1a`，`wait_confirm` 和 `wait_confirm_armed` 都会中止。
作者当时的回复是：这属于硬件故障，建议物理维修键盘，不建议为它开通用后门。

也就是说：**上游不会修这个，得自己改。**

## 代码层面：中止点在哪

两个文件，三处：

| 文件 | 函数 | 行为 |
|---|---|---|
| `loader/src/keywait.rs` | `wait_confirm` | 非空格/回车 → `Confirm::Abort` |
| `loader/src/keywait.rs` | `wait_confirm_armed` | 任意键 → `Confirm::Abort` |
| `loader/src/tx_prep.rs` | `armed_confirm_with_prep` | 任意键 → `Confirm::Abort`（tx 构建实际走这条） |

第三处容易被漏掉：**armed 模式在 tx 构建下根本不走 `wait_confirm_armed`**，
而是走 `tx_prep` 里那个把所有 prep 步骤和倒计时交错执行的循环。
日志里的模块名就是 `loader::tx_prep`。

## 关键日志（修复前）

```
17:  loader::tx_prep: CONFIRM: key Printable('\u{3}') during the 5s armed countdown - ABORT (no GPU writes this boot)
```

## 另一个发现：每次被中止都是"零写入"

```
ABORT to Windows, NOTHING was unlocked this boot (zero GPU writes)
```

这点让试错成本变低 —— 被中止一百次也不会伤到卡。
所以可以放心反复试，直到确认原因。
