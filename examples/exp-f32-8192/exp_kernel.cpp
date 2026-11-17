/*!
 * \file exp_kernel.cpp
 * \brief Exp kernel + tiling + launch wrappers (built with bisheng, -xasc).
 *
 * y = exp(x * mul + add), with mul = scale * ln(base) and add = shift * ln(base)
 * folded on the host. base <= 0 means natural base.
 */

#include <tuple>
#include <algorithm>
#include "kernel_operator.h"
#include "platform/platform_ascendc.h"

namespace {

constexpr int64_t PIPELINE_DEPTH = 2;

__aicore__ inline int64_t BlockSpan(int64_t totalLength, int64_t blockLength, int64_t blockIdx)
{
    int64_t begin = blockLength * blockIdx;
    if (begin >= totalLength) return 0;
    int64_t span = totalLength - begin;
    return span > blockLength ? blockLength : span;
}

} // namespace

__global__ __aicore__ void exp_kernel_f32(GM_ADDR x, GM_ADDR y, int64_t totalLength,
                                          int64_t blockLength, uint32_t tileSize,
                                          float mul, float add)
{
    const int64_t begin = blockLength * AscendC::GetBlockIdx();
    const int64_t span = BlockSpan(totalLength, blockLength, AscendC::GetBlockIdx());
    if (span <= 0) return;

    AscendC::TPipe pipe;
    AscendC::GlobalTensor<float> xGm;
    AscendC::GlobalTensor<float> yGm;
    AscendC::TQue<AscendC::QuePosition::VECIN, PIPELINE_DEPTH> inQueue;
    AscendC::TQue<AscendC::QuePosition::VECOUT, PIPELINE_DEPTH> outQueue;
    pipe.InitBuffer(inQueue, PIPELINE_DEPTH, tileSize);
    pipe.InitBuffer(outQueue, PIPELINE_DEPTH, tileSize);
    xGm.SetGlobalBuffer((__gm__ float *)x + begin);
    yGm.SetGlobalBuffer((__gm__ float *)y + begin);

    const int64_t elemsPerTile = tileSize / (int64_t)sizeof(float);
    for (int64_t offset = 0; offset < span; offset += elemsPerTile) {
        int64_t count = span - offset;
        if (count > elemsPerTile) count = elemsPerTile;
        AscendC::DataCopyExtParams copyParams{1, static_cast<uint32_t>(count * (int64_t)sizeof(float)), 0, 0, 0};
        AscendC::DataCopyPadExtParams<float> padParams{false, 0, 0, 0};

        auto xLocal = inQueue.AllocTensor<float>();
        AscendC::DataCopyPad(xLocal, xGm[offset], copyParams, padParams);
        inQueue.EnQue(xLocal);
        xLocal = inQueue.DeQue<float>();

        auto yLocal = outQueue.AllocTensor<float>();
        AscendC::Muls(yLocal, xLocal, mul, static_cast<int32_t>(count));
        AscendC::Adds(yLocal, yLocal, add, static_cast<int32_t>(count));
        AscendC::Exp(yLocal, yLocal, static_cast<int32_t>(count));
        outQueue.EnQue(yLocal);
        inQueue.FreeTensor(xLocal);

        yLocal = outQueue.DeQue<float>();
        AscendC::DataCopyPad(yGm[offset], yLocal, copyParams);
        outQueue.FreeTensor(yLocal);
    }
}

template <typename T>
__global__ __aicore__ void exp_kernel_cast(GM_ADDR x, GM_ADDR y, int64_t totalLength,
                                           int64_t blockLength, uint32_t tileSize,
                                           float mul, float add)
{
    const int64_t begin = blockLength * AscendC::GetBlockIdx();
    const int64_t span = BlockSpan(totalLength, blockLength, AscendC::GetBlockIdx());
    if (span <= 0) return;

    AscendC::TPipe pipe;
    AscendC::GlobalTensor<T> xGm;
    AscendC::GlobalTensor<T> yGm;
    AscendC::TQue<AscendC::QuePosition::VECIN, PIPELINE_DEPTH> inQueue;
    AscendC::TQue<AscendC::QuePosition::VECOUT, PIPELINE_DEPTH> outQueue;
    AscendC::TBuf<AscendC::TPosition::VECCALC> calcBufIn;
    AscendC::TBuf<AscendC::TPosition::VECCALC> calcBufOut;
    pipe.InitBuffer(inQueue, PIPELINE_DEPTH, tileSize);
    pipe.InitBuffer(outQueue, PIPELINE_DEPTH, tileSize);
    // Two-byte input widens to fp32 for the exp, so each scratch buffer is twice the tile.
    pipe.InitBuffer(calcBufIn, tileSize * 2);
    pipe.InitBuffer(calcBufOut, tileSize * 2);
    xGm.SetGlobalBuffer((__gm__ T *)x + begin);
    yGm.SetGlobalBuffer((__gm__ T *)y + begin);

    const int64_t elemsPerTile = tileSize / (int64_t)sizeof(T);
    for (int64_t offset = 0; offset < span; offset += elemsPerTile) {
        int64_t count = span - offset;
        if (count > elemsPerTile) count = elemsPerTile;
        const int32_t n = static_cast<int32_t>(count);
        AscendC::DataCopyExtParams copyParams{1, static_cast<uint32_t>(count * (int64_t)sizeof(T)), 0, 0, 0};
        AscendC::DataCopyPadExtParams<T> padParams{false, 0, 0, 0};

        auto xLocal = inQueue.AllocTensor<T>();
        AscendC::DataCopyPad(xLocal, xGm[offset], copyParams, padParams);
        inQueue.EnQue(xLocal);
        xLocal = inQueue.DeQue<T>();

        auto fIn = calcBufIn.Get<float>();
        auto fOut = calcBufOut.Get<float>();
        AscendC::Cast(fIn, xLocal, AscendC::RoundMode::CAST_NONE, n);
        AscendC::Muls(fOut, fIn, mul, n);
        AscendC::Adds(fOut, fOut, add, n);
        AscendC::Exp(fOut, fOut, n);

        auto yLocal = outQueue.AllocTensor<T>();
        AscendC::Cast(yLocal, fOut, AscendC::RoundMode::CAST_RINT, n);
        outQueue.EnQue(yLocal);
        inQueue.FreeTensor(xLocal);

        yLocal = outQueue.DeQue<T>();
        AscendC::DataCopyPad(yGm[offset], yLocal, copyParams);
        outQueue.FreeTensor(yLocal);
    }
}

std::tuple<int64_t, int64_t, int64_t> calc_exp_tiling_params(int64_t totalLength, int64_t elemBytes)
{
    constexpr int64_t MIN_ELEMS_PER_CORE = 1024;
    auto platform = platform_ascendc::PlatformAscendCManager::GetInstance();
    uint64_t ubSize = 0;
    platform->GetCoreMemSize(platform_ascendc::CoreMemType::UB, ubSize);
    int64_t coreNum = platform->GetCoreNumAiv();
    if (coreNum <= 0) coreNum = 1;
    if (totalLength <= 0) return std::make_tuple(1, 0, 0);

    int64_t numBlocks = std::min(coreNum, (totalLength + MIN_ELEMS_PER_CORE - 1) / MIN_ELEMS_PER_CORE);
    int64_t blockLength = (totalLength + numBlocks - 1) / numBlocks;
    // fp32: in(2x) + out(2x) fill UB. Two-byte: those plus two fp32 scratch buffers (2x each).
    const int64_t buffers = (elemBytes == 4) ? 4 : 8;
    int64_t tileSize = (static_cast<int64_t>(ubSize) - 1024) / buffers;
    tileSize -= tileSize % 32;
    return std::make_tuple(numBlocks, blockLength, tileSize);
}

extern "C" {

void launch_exp_kernel_float(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                             int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream)
{
    exp_kernel_f32<<<numBlocks, nullptr, stream>>>(x, y, totalLength, blockLength, tileSize, mul, add);
}

void launch_exp_kernel_half(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                            int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream)
{
    exp_kernel_cast<half><<<numBlocks, nullptr, stream>>>(x, y, totalLength, blockLength, tileSize, mul, add);
}

void launch_exp_kernel_bfloat16(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                                int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream)
{
    exp_kernel_cast<bfloat16_t><<<numBlocks, nullptr, stream>>>(x, y, totalLength, blockLength, tileSize, mul, add);
}

}
