"""BF16/FP16/FP32 matmul throughput probe.

The point is the *ratio*: the NVIDIA firmware PLM gate throttles tensor-core
matmul on the fp32-accumulate path to roughly half rate while it is closed.
Run this once with the unlock live and once after a plain reboot (stock) and
compare -- the f16/f32 and bf16 lines are the ones that move.
"""
import sys
import time

import torch


def bench(dtype, n=8192, iters=100, warmup=10):
    a = torch.randn(n, n, dtype=dtype, device="cuda")
    b = torch.randn(n, n, dtype=dtype, device="cuda")
    for _ in range(warmup):
        c = a @ b
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(iters):
        c = a @ b
    torch.cuda.synchronize()
    dt = time.perf_counter() - t0
    tflops = 2.0 * n * n * n * iters / dt / 1e12
    del a, b, c
    torch.cuda.empty_cache()
    return tflops


def main():
    if not torch.cuda.is_available():
        print("CUDA not available", file=sys.stderr)
        return 1
    name = torch.cuda.get_device_name(0)
    props = torch.cuda.get_device_properties(0)
    print(f"GPU     : {name}")
    print(f"SMs     : {props.multi_processor_count}   VRAM: {props.total_memory/2**30:.1f} GiB")
    print(f"torch   : {torch.__version__}   CUDA: {torch.version.cuda}")
    print("")

    results = {}
    for label, dt in (("fp16", torch.float16),
                      ("bf16", torch.bfloat16),
                      ("fp32", torch.float32)):
        try:
            t = bench(dt)
            results[label] = t
            print(f"{label:<6}: {t:9.2f} TFLOP/s")
        except Exception as exc:  # noqa: BLE001
            print(f"{label:<6}: FAILED - {exc}")

    print("")
    if "fp32" in results and results["fp32"] > 0:
        for k in ("fp16", "bf16"):
            if k in results:
                print(f"{k}/fp32 ratio: {results[k]/results['fp32']:.2f}x")
    print("")
    print("A closed PLM keeps fp16-f32acc and bf16 near ~half of their open")
    print("value, so fp16/fp32 and bf16/fp32 sit near 1.0x at stock and well")
    print("above it when the unlock is live.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
