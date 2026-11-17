#include <acl/acl.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <tuple>
#include "exp_launch.h"

int main(int argc, char** argv) {
    int64_t n = argc > 1 ? atoll(argv[1]) : 67108864LL;
    int reps = argc > 2 ? atoi(argv[2]) : 10;
    if (aclInit(nullptr) != ACL_SUCCESS) { printf("aclInit failed\n"); return 1; }
    aclrtSetDevice(0);
    aclrtStream stream = nullptr;
    aclrtCreateStream(&stream);
    void* x = nullptr;
    void* y = nullptr;
    const size_t bytes = static_cast<size_t>(n) * sizeof(float);
    aclrtMalloc(&x, bytes, ACL_MEM_MALLOC_HUGE_FIRST);
    aclrtMalloc(&y, bytes, ACL_MEM_MALLOC_HUGE_FIRST);
    aclrtMemset(x, bytes, 0, bytes);
    auto t = calc_exp_tiling_params(n, 4);
    int64_t nb = std::get<0>(t);
    int64_t bl = std::get<1>(t);
    uint32_t ts = static_cast<uint32_t>(std::get<2>(t));
    for (int i = 0; i < reps; ++i) {
        launch_exp_kernel_float(x, y, n, nb, bl, ts, 1.0f, 0.0f, stream);
    }
    aclrtSynchronizeStream(stream);
    float host = -1.0f;
    aclrtMemcpy(&host, sizeof(float), static_cast<uint8_t*>(y), sizeof(float), ACL_MEMCPY_DEVICE_TO_HOST);
    printf("n=%lld blocks=%lld blocklen=%lld tile=%u reps=%d y[0]=%f\n",
           static_cast<long long>(n), static_cast<long long>(nb), static_cast<long long>(bl), ts, reps, host);
    aclrtDestroyStream(stream);
    aclrtFree(x);
    aclrtFree(y);
    aclrtResetDevice(0);
    aclFinalize();
    return 0;
}
