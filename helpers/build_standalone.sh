#!/usr/bin/env bash
# Build an AscendC kernel plus an ACL host harness into one executable that msopprof can run.
#
#   build_standalone.sh <kernel_dir> <kernel.cpp> <bench.cpp> <out_binary> [npu_arch]
#
# kernel.cpp must define the __global__ __aicore__ kernels and an extern "C" launcher set.
# bench.cpp is plain ACL host code and must not include kernel headers that need -xasc.
set -euo pipefail

KERNEL_DIR=${1:?kernel dir}
KERNEL_SRC=${2:?kernel source (.cpp)}
BENCH_SRC=${3:?bench source (.cpp)}
OUT=${4:?output binary}
NPU_ARCH=${5:-dav-2201}

CANN=${ASCEND_HOME_PATH:-/usr/local/Ascend/cann-9.1.0}
[[ -d "$CANN" ]] || CANN=$(ls -d /usr/local/Ascend/cann-* 2>/dev/null | sort -V | tail -1)
BISHENG="$CANN/aarch64-linux/ccec_compiler/bin/bisheng"
[[ -x "$BISHENG" ]] || { echo "no bisheng under $CANN" >&2; exit 1; }

INC="-I$KERNEL_DIR -I$CANN/include -I$CANN/compiler/tikcpp/include \
-I$CANN/compiler/ascendc/include/basic_api/impl \
-I$CANN/compiler/ascendc/include/basic_api/interface \
-I$CANN/compiler/ascendc/include/highlevel_api/impl \
-I$CANN/compiler/ascendc/include/highlevel_api/tiling \
-I$CANN/compiler/ascendc/impl/aicore/basic_api"

LIB_EXTRA=""
# A bare openEuler host has gcc but no C++ standard headers. The toolkit carries its own; they go in
# CPLUS_INCLUDE_PATH because the compiler's generated units inherit no -I flags.
if [[ ! -d /usr/include/c++ ]]; then
    HCC="$CANN/tools/hcc/aarch64-target-linux-gnu"
    if [[ -d "$HCC/include/c++" ]]; then
        VERSIONED=$(ls -d "$HCC"/include/c++/*/ | head -1)
        export CPLUS_INCLUDE_PATH="${VERSIONED}:${VERSIONED}aarch64-target-linux-gnu:${CPLUS_INCLUDE_PATH:-}"
        LIB_EXTRA="-L$HCC/lib64"
        echo "== no system C++ headers, using $VERSIONED" >&2
    fi
fi

OBJ_DIR=$(mktemp -d)
trap 'rm -rf "$OBJ_DIR"' EXIT

echo "== kernel (bisheng --npu-arch=$NPU_ARCH -xasc)"
$BISHENG --npu-arch="$NPU_ARCH" -xasc -O3 -DNDEBUG -std=gnu++17 $INC -c "$KERNEL_SRC" -o "$OBJ_DIR/kernel.o"
echo "== host"
$BISHENG -O3 -std=gnu++17 $INC -c "$BENCH_SRC" -o "$OBJ_DIR/bench.o"
echo "== link"
$BISHENG -O3 -std=gnu++17 -o "$OUT" "$OBJ_DIR/bench.o" "$OBJ_DIR/kernel.o" \
    $LIB_EXTRA -L"$CANN/lib64" -lascendcl -lplatform -lregister -ltiling_api -lruntime

chmod 755 "$OUT"

# msopprof refuses to run an application from a group- or world-writable directory.
OUT_DIR=$(cd "$(dirname "$OUT")" && pwd)
if [[ -n "$(find "$OUT_DIR" -maxdepth 0 -perm /022 2>/dev/null)" ]]; then
    echo "WARNING: $OUT_DIR is group- or world-writable; msopprof will refuse it." >&2
    echo "         chmod 755 $OUT_DIR" >&2
fi

ls -l "$OUT"
