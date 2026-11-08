# 06 · 实测

## 方法

用 PyTorch 跑固定尺寸的矩阵乘法，比较三种精度：

```python
a = torch.randn(8192, 8192, dtype=dt, device="cuda")
b = torch.randn(8192, 8192, dtype=dt, device="cuda")
# 10 次 warmup，100 次计时
tflops = 2 * n**3 * iters / elapsed / 1e12
```

脚本：[`scripts/bench_bf16.py`](../scripts/bench_bf16.py)

**为什么这个能反映解锁**：cuBLAS 对 `fp16` / `bf16` 输入默认走 `CUBLAS_COMPUTE_32F`
（fp32 累加），而 PLM 门控限制的正是这条 fp32 累加通路。所以半精度 matmul 的吞吐
直接受开关影响，`fp32` 不受影响。

## 环境

```
torch 2.14.1+cu126   CUDA 12.6
RTX 4060 Laptop GPU (AD107, 24 SM, 8 GiB)
驱动 576.88
```

## 数据

| | stock（重启后未解锁） | unlocked（开机 loader 跑过） | 变化 |
|---|---:|---:|---:|
| **bf16** | 27.20 TFLOP/s | **40.94 TFLOP/s** | **+50.5%** |
| **fp16** | 26.79 TFLOP/s | **40.12 TFLOP/s** | **+49.8%** |
| fp32 | 6.70 TFLOP/s | 6.78 TFLOP/s | +1.2%（噪声） |

多轮复现一致：

```
unlocked  bf16: 40.71 / 40.94 / 40.94
stock     bf16: 27.20
```

比例：

```
unlocked   fp16/fp32 = 5.91x   bf16/fp32 = 6.03x
stock      fp16/fp32 = 4.00x   bf16/fp32 = 4.06x
```

## 寄存器侧对照

```
0x823xxx PLM       = 0xffffffff      (OPEN)
0x823xxx SS0       = 0x88888888
0x823xxx SS1       = 0x00000008
0x823xxx READOUT_1 = 0x00000000      [full speed]
```

`ssdiag` 判定：`VERDICT [ada]: UNLOCKED (override values live)`

## 关于 1.5x

上游记录里 AD102（4090）的 f16/f32 是 **2x**（88.8 → 177.4 TFLOP/s）。

这台只有 **1.5x**。可能的原因：

- AD107 这颗的 PLM 本来就只限制到 3/4
- 笔记本 90 W 功耗墙先卡住了，满速跑不满
- 8192³ 这个尺寸下 cuBLAS 的效率本身就在 74% 左右

不确定是哪个，没做进一步隔离。**能确定的是 fp32 完全没动，只有 tensor 路径变了**，
这个符合预期。

## 复现步骤

```powershell
# 解锁状态
python .\scripts\bench_bf16.py

# 拿基线：正常重启（不经过 loader，把 Boot0000 指回 Windows），再跑一次
```

脚本会打印 fp16/fp32 和 bf16/fp32 的比值。解锁前后这两个数会明显不同
（4.0x vs 6.0x），比绝对值更容易判断。

## 其他观察

- `36 TPC(s) fused off in 8 GPC(s), no defect bit on them` —— `ssdiag` 顺带发现
  有 36 个 TPC 被熔断但没标缺陷位，理论上是可恢复候选。**这条不在本文范围内**，
  风险比 selector 解锁高得多，没试。
