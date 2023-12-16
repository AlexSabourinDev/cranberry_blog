StructuredBuffer<float2> Values;
RWStructuredBuffer<float> Output;

struct PushConstants
{
	uint Count;
};
[[vk::push_constant]] PushConstants Constants;

#define ALLOW_SPIRV_OPS

#if defined(__spirv__) && defined(ALLOW_SPIRV_OPS)

// Inline SPIR-V https://github.com/microsoft/DirectXShaderCompiler/wiki/GL_EXT_spirv_intrinsics-for-SPIR-V-code-gen
[[vk::ext_instruction(/* OpGroupNonUniformBallotFindMSB */ 344)]]
uint OpGroupNonUniformBallotFindMSB(uint scope, uint4 ballot);

uint WaveGetLastLaneIndex()
{
	uint4 ballot = WaveActiveBallot(true);

	// https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html#Scope_-id-
	uint const SubgroupScope = 3;
	// Scope must be Subgroup.
	return OpGroupNonUniformBallotFindMSB(SubgroupScope, ballot);
}
#else

uint WaveGetLastLaneIndex()
{
	uint4 ballot = WaveActiveBallot(true);
	uint4 bits = firstbithigh(ballot); // Returns -1 (0xFFFFFFFF) if no bits set.
	
    // For reasons unclear to me, firstbithigh causes us to consider `bits` as a vector when compiling for RDNA
    // This then causes us to generate a waterfall loop later on in WaveReadLaneAt :(
    // Force scalarization here. See: https://godbolt.org/z/barT3rM3W
    bits = WaveReadLaneFirst(bits);
    bits = select(bits == 0xFFFFFFFF, 0, bits + uint4(0, 32, 64, 96));

	return max(max(max(bits.x, bits.y), bits.z), bits.w);
}

#endif // !(defined(__spirv__) && defined(ALLOW_SPIRV_OPS))

float WaveReadLaneLast(float t)
{
	uint lastLane = WaveGetLastLaneIndex();
	return WaveReadLaneAt(t, lastLane);
}

// Interpolates as lerp(lerp(Lane2, Lane1, t1), Lane0, t0), etc
// 
// NOTE: Values need to be sorted in order of last interpolant to first interpolant.
// 
// As an example, say we have the loop:
// for(int i = 0; i < 4; i++)
//    result = lerp(result, values[i], interpolations[i]);
// 
// Lane0 should hold the last value, i.e. values[3]. NOT values[0].
// 
// WaveActiveLerp instead implements the loop as a reverse loop:
// for(int i = 3; i >= 0; i--)
//    result = lerp(result, values[i], interpolations[i]);
// 
// return.x == result of the wave's interpolation
// return.y == product of all the wave's (1-t) for continued interpolation.
float2 WaveActiveLerp(float value, float t)
{
	// lerp(v1, v0, t0) = v1 * (1 - t0) + v0 * t0
	// lerp(lerp(v2, v1, t1), v0, t0)
	// = (v2 * (1 - t1) + v1 * t1) * (1 - t0) + v0 * t0
	// = v2 * (1 - t1) * (1 - t0) + v1 * t1 * (1 - t0) + v0 * t0

	// We can then split the elements of our sum for each thread.
	// Lane0 = v0 * t0
	// Lane1 = v1 * t1 * (1 - t0)
	// Lane2 = v2 * (1 - t1) * (1 - t0)

	// As you can see, each thread's (1 - tn) term is simply the product of the previous thread's terms.
	// We can achieve this result by using WavePrefixProduct
		
	float prefixProduct = WavePrefixProduct(1.0f - t);
	float laneValue = value * t * prefixProduct;
	float interpolation = WaveActiveSum(laneValue);

	// If you don't need this for a continued interpolation, you can simply remove this part.
	float postfixProduct = prefixProduct * (1.0f - t);
	float oneMinusT = WaveReadLaneLast(postfixProduct);

	return float2(interpolation, oneMinusT);
}

// Assume WaveSize of 32.
static uint const ThreadGroupSize = 32;

[numthreads(ThreadGroupSize,1,1)]
void CS(uint3 dispatchId : SV_DispatchThreadId)
{
	float result = 0.0f;

	float continuedProduct = 1.0f;
	for(uint i = dispatchId.x; i < Constants.Count; i += ThreadGroupSize)
	{
		float2 value = Values[i];

		float2 interpolation = WaveActiveLerp(value.x, value.y);
		result += interpolation.x * continuedProduct;
		continuedProduct *= interpolation.y;
	}

	if(dispatchId.x == 0)
	{
		Output[0] = result;
	}
}