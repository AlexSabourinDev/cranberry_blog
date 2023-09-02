#include "sample_blur.hsh"

static const uint2 BlurThreadGroupSize = int2(InlineBlurThreadGroupWidth, InlineBlurThreadGroupHeight);

#ifdef USE_INLINE_HORIZONTAL_GS
static uint const MaxCacheWidth = InlineBlurThreadGroupWidth + MaxBlurRadius * 2;
#else
static uint const MaxCacheWidth = InlineBlurThreadGroupWidth;
#endif

static uint const MaxCacheHeight = InlineBlurThreadGroupHeight + MaxBlurRadius * 2;

groupshared CacheFormat Texel2DCache[MaxCacheWidth * MaxCacheHeight];
uint toCacheIndex(int2 readIndex)
{
	return readIndex.y * MaxCacheWidth + readIndex.x;
}

void loadGroupShared2DCache(uint2 threadId, uint2 threadGroupOrigin)
{
	uint blurRadius = BlurConstants.BlurRadius;
	int2 loadOrigin = (int2)threadGroupOrigin-int2(blurRadius, blurRadius);

	uint loadHeight = InlineBlurThreadGroupHeight + blurRadius * 2;
	uint loadWidth = InlineBlurThreadGroupWidth + blurRadius * 2;
	for(uint y = 0; y < loadHeight; y += InlineBlurThreadGroupHeight)
	{
		for (uint x = 0; x < loadWidth; x += InlineBlurThreadGroupWidth)
		{
			int2 cache2DIndex = int2(x,y) + threadId;
			[branch]
			if (all(cache2DIndex < int2(loadWidth, loadHeight)))
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

[numthreads(InlineBlurThreadGroupWidth, InlineBlurThreadGroupHeight, 1)]
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 threadGroupId : SV_GroupThreadID,
	uint3 dispatchId : SV_DispatchThreadID)
{
#ifdef USE_ZCURVE
	static uint const blockSize = InlineBlurThreadGroupWidth * InlineBlurThreadGroupWidth;
	uint subBlockId = threadIndex / blockSize;
	uint subBlockThreadIndex = threadIndex % blockSize;

	threadGroupId.xy = zCurve(subBlockThreadIndex, InlineBlurThreadGroupWidth) + int2(0, subBlockId * InlineBlurThreadGroupWidth);
	dispatchId.xy = threadGroupId.xy + groupId * BlurThreadGroupSize;
#endif // USE_ZCURVE

#ifdef USE_INLINE_HORIZONTAL_GS
	loadGroupShared2DCache(threadGroupId.xy, groupId * BlurThreadGroupSize);
	GroupMemoryBarrierWithGroupSync();
#endif // USE_INLINE_HORIZONTAL_GS

#ifdef USE_INLINE_HORIZONTAL_GS
	int2 const CacheOffset = int2(BlurConstants.BlurRadius, BlurConstants.BlurRadius);
#else
	int2 const CacheOffset = int2(0, BlurConstants.BlurRadius);
#endif // USE_INLINE_HORIZONTAL_GS

	// Do our horizontal blur followed by our vertical blur
	int loadHeight = InlineBlurThreadGroupHeight + BlurConstants.BlurRadius * 2;
	for (int yChunk = 0; yChunk < loadHeight; yChunk += InlineBlurThreadGroupHeight)
	{
		int2 readIndex = threadGroupId.xy + int2(CacheOffset.x, yChunk);
		
		TexelFormat blur = 0.0f;
		[branch]
		if (readIndex.y < loadHeight)
		{
			for (uint i = 0; i < BlurConstants.SampleCount; i += 4)
			{
				uint4 samples = loadSample4(i);
				for (uint u = 0; u < 4; u++)
				{
					if (i + u < BlurConstants.SampleCount)
					{
						Sample unpackedSample = unpackSample(samples[u]);

#ifdef USE_INLINE_HORIZONTAL_GS
						// Y axis doesn't have the blur radius bump since we want to start at the very top of our box.
						uint cacheIndex = toCacheIndex(readIndex + unpackedSample.Offset.xy);
						blur += Texel2DCache[cacheIndex] * unpackedSample.Weight;
#else
						int2 texIndex = dispatchId.xy + int2(0, yChunk - BlurConstants.BlurRadius) + unpackedSample.Offset.xy;
						texIndex = clamp(texIndex, int2(0, 0), int2(BlurConstants.SourceWidth - 1, BlurConstants.SourceHeight - 1));
						blur += Source[texIndex] * unpackedSample.Weight;
#endif // USE_INLINE_HORIZONTAL_GS
					}
				}
			}
		}

#ifdef USE_INLINE_HORIZONTAL_GS
		GroupMemoryBarrierWithGroupSync();
#endif // USE_INLINE_HORIZONTAL_GS

		[branch]
		if (readIndex.y < loadHeight)
		{
			uint cacheWriteIndex = toCacheIndex(readIndex);
			Texel2DCache[cacheWriteIndex] = (CacheFormat)blur;
		}
	}

	// Wait until all our horizontal blurs are done.
	GroupMemoryBarrierWithGroupSync();

	TexelFormat blur = 0.0f;
	int2 readIndex = int2(threadGroupId.xy) + CacheOffset;
	for (uint i = 0; i < BlurConstants.SampleCount; i += 4)
	{
		uint4 samples = loadSample4(i);
		for (uint u = 0; u < 4; u++)
		{
			if (i + u < BlurConstants.SampleCount)
			{
				Sample unpackedSample = unpackSample(samples[u]);

				uint cacheIndex = toCacheIndex(readIndex + unpackedSample.Offset.yx); // flip sample offset
				blur += Texel2DCache[cacheIndex] * unpackedSample.Weight;
			}
		}
	}

	// Only skip out of bound writes
	// Continue all the remaining execution since we expect our threadgroup to work as a unit
	[branch]
	if (all(dispatchId.xy < uint2(BlurConstants.SourceWidth, BlurConstants.SourceHeight)))
	{
		Output[dispatchId.xy] = blur;
	}
}