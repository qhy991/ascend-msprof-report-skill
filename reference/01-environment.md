# Environment

Everything here was verified on 2026-11-17 against `cann-bench-eval:1.0.0-ascend910_93-aarch64-opsnone`
(CANN 9.1.0, torch_npu 2.10.0.post4) and the bare host (CANN 8.5.0, driver 25.5.0) on a
16-die 910C node. Treat it as a starting point and re-check the two versioned paths on a new machine.

## Identification

| What | Value | How it was read |
|---|---|---|
| Device name | `Ascend910_9382` | `torch.npu.get_device_name(0)` |
| Dies visible | 16 | `aclrtGetDeviceCount` |
| Compile short name | `ascend910_93` | `SOC_TO_SHORT_SOC_MAP`, used for `opp/.../config/<short>` |
| Bisheng target | `dav-2201` | the submission CMake maps 910B and 910_93 to it |
| Toolkit in eval image | 9.1.0 | `/usr/local/Ascend/cann-9.1.0` |
| Toolkit on bare host | 8.5.0 | `/usr/local/Ascend/cann-8.5.0` |

`npu-smi info` reports only the base class (`Ascend910`). Use `torch.npu.get_device_name(0)` or
`acl.get_soc_name()` when the exact sub-model matters.

## Container flags

```
--privileged --ipc=host \
--device /dev/davinci_manager --device /dev/devmm_svm --device /dev/hisi_hdc \
-v /usr/local/Ascend/driver:/usr/local/Ascend/driver:ro \
-v /usr/local/dcmi:/usr/local/dcmi:ro
```

**Add `--network=host` when the host dockerd has no bridge.** A host whose `docker0` is absent fails
container start with `adding interface veth... to bridge docker0 failed: could not find bridge
docker0`, and that failure looks like a profiler problem until you read the message.

## Environment variables

The image's `/etc/cann-env.sh` (sourced via `BASH_ENV`) is the source of truth. On this image it sets:

```
ASCEND_HOME_PATH=/usr/local/Ascend/cann-9.1.0
ASCEND_OPP_PATH=/usr/local/Ascend/cann-9.1.0/opp
ASCEND_AICPU_PATH=/usr/local/Ascend/cann-9.1.0
PYTHONPATH=/usr/local/Ascend/cann-9.1.0/python/site-packages:.../opp/built-in/op_impl/ai_core/tbe:
```

**Do not source `/usr/local/Ascend/ascend-toolkit/set_env.sh` on top of a correctly configured
container.** On this image `ascend-toolkit/latest` and `cann-9.1.0` resolve to different trees, and
re-sourcing repoints `ASCEND_OPP_PATH` at one that has no op info library. The symptom is
`GEInitialize` failing with `FEOpsKernelInfoStore: Initialize custom and builtin sub-information
library failed`, which reads like a driver fault and is really a path fault.

## The torch trap in a stripped image

`OPS_MODE=none` (the default for `ascend910_93`) removes the builtin op package. Consequences:

- `import torch_npu` and `torch.npu.get_device_name(0)` still work.
- Any real device tensor fails: `torch.randn(4, device='npu')` raises
  `SetPrecisionMode ... error code is 500001` and then the `GEInitialize` stack above.
- The benchmark harness is unaffected because it installs and calls a direct-launch custom op.

So a profiling harness for a submission must not go through torch in this image. Build a standalone
ACL binary. If you need torch for model-level work, use an image built with `OPS_MODE=refonly`.

## Building a standalone kernel binary

The kernel translation unit must be compiled by Bisheng with `-xasc`, and the host `main` compiled
separately and linked against the Ascend runtimes.

```bash
CANN=/usr/local/Ascend/cann-9.1.0
BISHENG=$CANN/aarch64-linux/ccec_compiler/bin/bisheng
INC="-I<kernel dir> -I$CANN/include -I$CANN/compiler/tikcpp/include \
     -I$CANN/compiler/ascendc/include/basic_api/impl \
     -I$CANN/compiler/ascendc/include/basic_api/interface \
     -I$CANN/compiler/ascendc/include/highlevel_api/impl \
     -I$CANN/compiler/ascendc/include/highlevel_api/tiling \
     -I$CANN/compiler/ascendc/impl/aicore/basic_api"

$BISHENG --npu-arch=dav-2201 -xasc -O3 -std=gnu++17 $INC -c kernel.cpp -o kernel.o
$BISHENG -O3 -std=gnu++17 $INC -c bench.cpp -o bench.o
$BISHENG -O3 -std=gnu++17 -o bench bench.o kernel.o \
  -L$CANN/lib64 -lascendcl -lplatform -lregister -ltiling_api -lruntime
```

`helpers/build_standalone.sh` runs exactly this and takes the kernel directory as an argument.

Build warnings of the form `kernel type of __global__ func ... is not marked. auto type derivate may
be failed.` are benign for a kernel launched through an explicit `<<<blocks, nullptr, stream>>>`
wrapper: the block count is supplied at the launch site, so nothing needs deriving.

## Host-side harness requirements

`main` must set up ACL before calling any launcher, because tiling helpers query the platform:

```cpp
aclInit(nullptr);
aclrtSetDevice(0);
aclrtStream stream = nullptr;
aclrtCreateStream(&stream);
aclrtMalloc(&x, bytes, ACL_MEM_MALLOC_HUGE_FIRST);
```

and tear down with `aclrtSynchronizeStream`, `aclrtDestroyStream`, `aclrtFree`, `aclrtResetDevice`,
`aclFinalize`. `examples/exp-f32-8192/exp_bench.cpp` is a complete 39-line example.
