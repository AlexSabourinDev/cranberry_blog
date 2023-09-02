#include "sample_blur.hsh"

#ifdef HORIZONTAL
static uint const ThreadGroupX = SlidingWindowBlurWidth;
static uint const ThreadGroupY = SlidingWindowBlurHeight;
static uint2 const ThreadGroupSize = uint2(SlidingWindowBlurWidth, SlidingWindowBlurHeight);
#else
static uint const ThreadGroupX = SlidingWindowBlurHeight;
static uint const ThreadGroupY = SlidingWindowBlurWidth;
static uint2 const ThreadGroupSize = uint2(SlidingWindowBlurHeight, SlidingWindowBlurWidth);
#endif

static uint const MaxCacheWidth = SlidingWindowBlurWidth + MaxBlurRadius * 2;

#ifdef HORIZONTAL
static int2 const BlurAxis = int2(1, 0);
#else
static int2 const BlurAxis = int2(0, 1);
#endif

groupshared CacheFormat Texel1DCache[MaxCacheWidth * SlidingWindowBlurHeight];
uint toCacheIndex(int2 readIndex)
{
#ifdef HORIZONTAL
	return readIndex.x % MaxCacheWidth + readIndex.y * MaxCacheWidth;
#else
	return readIndex.y % MaxCacheWidth + readIndex.x * MaxCacheWidth;
#endif
}

void loadGroupShared1DCache(uint2 threadGroupId,
	uint2 threadGroupOrigin,
	int slidingWindowOffset,
	uint loadWidth)
{
	uint blurRadius = BlurConstants.BlurRadius;

	int2 loadOrigin = (int2)threadGroupOrigin+BlurAxis*(slidingWindowOffset-blurRadius);
	for(uint i = 0; i < loadWidth; i += SlidingWindowBlurWidth)
	{
#ifdef HORIZONTAL
		bool writeValid = (threadGroupId.x + i) < loadWidth;
#else
		bool writeValid = (threadGroupId.y + i) < loadWidth;
#endif // HORIZONTAL

		uint2 cacheIndex2D = threadGroupId + BlurAxis*i;
		[branch]
		if(writeValid)
		{
			int2 readIndex = loadOrigin + (int2)cacheIndex2D;
			readIndex = clamp(readIndex,
				int2(0,0), int2(BlurConstants.SourceWidth-1, BlurConstants.SourceHeight-1));

			uint cacheIndex = toCacheIndex(cacheIndex2D + BlurAxis*slidingWindowOffset);
			Texel1DCache[cacheIndex] = (CacheFormat)Source[readIndex];
		}
	}
}

[numthreads(ThreadGroupX, ThreadGroupY, 1)]
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 threadGroupId : SV_GroupThreadID,
	uint3 dispatchId : SV_DispatchThreadID)
{
#ifdef USE_ZCURVE

	static uint const blockSize = SlidingWindowBlurHeight * SlidingWindowBlurHeight;
	uint subBlockId = threadIndex / blockSize;
	uint subBlockThreadIndex = threadIndex % blockSize;

	threadGroupId.xy = zCurve(subBlockThreadIndex, SlidingWindowBlurHeight) + BlurAxis * (subBlockId * SlidingWindowBlurHeight);
	dispatchId.xy = threadGroupId.xy + groupId * ThreadGroupSize;

#endif // USE_ZCURVE

	uint preloadWidth = BlurConstants.BlurRadius * 2;
	loadGroupShared1DCache(threadGroupId.xy, groupId * ThreadGroupSize, 0, preloadWidth);
	GroupMemoryBarrierWithGroupSync();

	int slidingWindowProcessOffset = 0;
	int slidingWindowReadOffset = preloadWidth;

#ifdef HORIZONTAL
	while(slidingWindowProcessOffset < BlurConstants.SourceWidth)
#else
	while(slidingWindowProcessOffset < BlurConstants.SourceHeight)
#endif
	{
		// Load our next chunk
		{
			loadGroupShared1DCache(threadGroupId.xy, groupId * ThreadGroupSize, slidingWindowReadOffset, SlidingWindowBlurWidth);
			GroupMemoryBarrierWithGroupSync();
			slidingWindowReadOffset += SlidingWindowBlurWidth;
		}

		uint2 writeIndex = dispatchId.xy + BlurAxis * slidingWindowProcessOffset;
		[branch]
		if (all(writeIndex < uint2(BlurConstants.SourceWidth, BlurConstants.SourceHeight)))
		{
			TexelFormat blur = 0.0f;
			int2 readIndex = int2(threadGroupId.xy) + BlurAxis*(BlurConstants.BlurRadius + slidingWindowProcessOffset);
			for(uint i = 0; i < BlurConstants.SampleCount; i+=4)
			{
				uint4 samples = loadSample4(i);
				for (uint u = 0; u < 4; u++)
				{
					if (i + u < BlurConstants.SampleCount)
					{
						Sample unpackedSample = unpackSample(samples[u]);

						uint cacheIndex = toCacheIndex(readIndex + unpackedSample.Offset);
						blur += Texel1DCache[cacheIndex] * unpackedSample.Weight;
					}
				}
			}

			Output[writeIndex] = blur;
		}

		slidingWindowProcessOffset += SlidingWindowBlurWidth;
	}
}