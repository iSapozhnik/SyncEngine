//
//  shader.metal
//  CloudTest
//
//  Created by Ivan Sapozhnik on 13.11.24.
//

#include <metal_stdlib>
using namespace metal;

kernel void upscaleKernel(texture2d<float, access::sample> inputTexture [[texture(0)]],
                         texture2d<float, access::write> outputTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler textureSampler(filter::linear,
                                   address::clamp_to_edge,
                                   coord::normalized);
    
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 texCoord = float2(gid) / outputSize;
    
    float4 color = inputTexture.sample(textureSampler, texCoord);
    outputTexture.write(color, gid);
}
