#include "sample_blur.hsh"

static uint const MaxCacheWidth = BlurThreadGroupWidth + MaxBlurRadius * 2;

groupshared CacheFormat Texel2DCache[MaxCacheWidth * MaxCacheWidth];
uint toCacheIndex(int2 readIndex)
{
	return readIndex.y * MaxCacheWidth + readIndex.x;
}

void loadGroupShared2DCache(uint2 threadId, uint2 threadGroupOrigin)
{
	uint blurRadius = BlurConstants.BlurRadius;
	int2 loadOrigin = (int2)threadGroupOrigin - int2(blurRadius, blurRadius);

	uint loadWidth = BlurThreadGroupWidth + blurRadius * 2;
	for (uint y = 0; y < loadWidth; y += BlurThreadGroupWidth)
	{
		for (uint x = 0; x < loadWidth; x += BlurThreadGroupWidth)
		{
			int2 cache2DIndex = int2(x, y) + threadId;
			[branch]
			if (all(cache2DIndex < loadWidth))
			{
				int2 readIndex = loadOrigin + cache2DIndex;
				readIndex = clamp(readIndex,
					int2(0, 0), int2(BlurConstants.SourceWidth - 1, BlurConstants.SourceHeight - 1));

				uint cacheIndex = toCacheIndex(cache2DIndex);
				Texel2DCache[cacheIndex] = (CacheFormat)Source[readIndex];
			}
		}
	}
}

[numthreads(BlurThreadGroupWidth, BlurThreadGroupWidth, 1)]
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 threadGroupId : SV_GroupThreadID,
	uint3 dispatchId : SV_DispatchThreadID)
{
	// Only load our groupshared with Z curves since that's when we access texture memory.
#ifdef USE_ZCURVE
	uint2 loadThreadId = zCurve(threadIndex, BlurThreadGroupWidth);
#else
	uint2 loadThreadId = threadGroupId.xy;
#endif // USE_ZCURVE

	loadGroupShared2DCache(loadThreadId, groupId * BlurThreadGroupWidth);
	GroupMemoryBarrierWithGroupSync();

	[branch]
	if (any(dispatchId.xy >= uint2(BlurConstants.SourceWidth, BlurConstants.SourceHeight)))
	{
		return;
	}

	TexelFormat blur = 0.0f;

	int2 readIndex = int2(threadGroupId.xy) + BlurConstants.BlurRadius;
	for(uint i = 0; i < BlurConstants.SampleCount; i+=4)
	{
		uint4 samples = loadSample4(i);
		for (uint u = 0; u < 4; u++)
		{
			if (i + u < BlurConstants.SampleCount)
			{
				Sample unpackedSample = unpackSample(samples[u]);

				uint cacheIndex = toCacheIndex(readIndex + unpackedSample.Offset);
				blur += Texel2DCache[cacheIndex] * unpackedSample.Weight;
			}
		}
	}
	Output[dispatchId.xy] = blur;
}