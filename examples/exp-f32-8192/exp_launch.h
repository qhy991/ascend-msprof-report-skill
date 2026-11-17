/*!
 * \file exp_launch.h
 * \brief Launch declarations for the Exp kernel (visible to g++).
 */

#ifndef EXP_LAUNCH_H
#define EXP_LAUNCH_H

#include <cstdint>
#include <tuple>

#ifndef GM_ADDR
#define GM_ADDR void*
#endif

// numBlocks, blockLength, tileSize(bytes). elemBytes picks the UB budget: the cast path
// needs two fp32 scratch buffers on top of in/out, the fp32 path does not.
std::tuple<int64_t, int64_t, int64_t> calc_exp_tiling_params(int64_t totalLength, int64_t elemBytes);

extern "C" {
void launch_exp_kernel_float(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                             int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream);
void launch_exp_kernel_half(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                            int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream);
void launch_exp_kernel_bfloat16(GM_ADDR x, GM_ADDR y, int64_t totalLength, int64_t numBlocks,
                                int64_t blockLength, uint32_t tileSize, float mul, float add, void* stream);
}

#endif // EXP_LAUNCH_H
