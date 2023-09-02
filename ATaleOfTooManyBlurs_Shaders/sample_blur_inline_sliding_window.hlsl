#include "sample_blur.hsh"

#ifdef HORIZONTAL_GROUPSHARED
static uint const MaxCacheWidth = InlineSlidingWindowBlurWidth + MaxBlurRadius * 2;
static uint const MaxCacheHeight = InlineSlidingWindowBlurHeight + MaxBlurRadius * 2;
static int2 const GroupSharedOffset = int2(BlurConstants.BlurRadius, BlurConstants.BlurRadius);

#else
static uint const MaxCacheWidth = InlineSlidingWindowBlurWidth;
static uint const MaxCacheHeight = InlineSlidingWindowBlurHeight + MaxBlurRadius * 2;

// No blur radius offset for our pass without horizontal groupshared
static int2 const GroupSharedOffset = int2(0, BlurConstants.BlurRadius);
#endif

groupshared CacheFormat HorizontalCache[MaxCacheWidth * InlineSlidingWindowBlurHeight];
uint toHorizontalCacheIndex(int2 readIndex)
{
	return readIndex.y * MaxCacheWidth + readIndex.x;
}

groupshared CacheFormat VerticalCache[InlineSlidingWindowBlurWidth * MaxCacheHeight];
uint toVerticalCacheIndex(int2 readIndex)
{
	return (readIndex.y % MaxCacheHeight) * InlineSlidingWindowBlurWidth + readIndex.x;
}

void loadGroupShared2DCache(uint2 threadId, uint threadGroupOriginX, int readOffset)
{
	uint loadWidth = InlineSlidingWindowBlurWidth + BlurConstants.BlurRadius * 2;
	for (uint x = 0; x < loadWidth; x += InlineSlidingWindowBlurWidth)
	{
		[branch]
		if (x + threadId.x < loadWidth)
		{
			int2 loadOrigin = int2(threadGroupOriginX, readOffset) - GroupSharedOffset;

			int2 readIndex = loadOrigin + int2(x + threadId.x, threadId.y);
			readIndex = clamp(readIndex,
				int2(0, 0), int2(BlurConstants.SourceWidth - 1, BlurConstants.SourceHeight - 1));

			uint cacheIndex = toHorizontalCacheIndex(uint2(threadId.x + x, threadId.y));
			HorizontalCache[cacheIndex] = (CacheFormat)Source[readIndex];
		}
	}
}

void groupSharedHorizontalBlurPass(uint2 loadThreadId, uint2 threadGroupId, uint2 groupId, int loadHeight, int slidingWindowReadOffset)
{
	for (int yChunk = 0; yChunk < loadHeight; yChunk += InlineSlidingWindowBlurHeight)
	{
		// Load the memory we need for our horizontal pass into our cache
		loadGroupShared2DCache(loadThreadId, groupId.x * InlineSlidingWindowBlurWidth, yChunk + slidingWindowReadOffset);
		GroupMemoryBarrierWithGroupSync();

		int2 readIndex = threadGroupId.xy + int2(GroupSharedOffset.x, 0);

		TexelFormat blur = 0.0f;
		[branch]
		if (yChunk + threadGroupId.y < loadHeight)
		{
			for (uint i = 0; i < BlurConstants.SampleCount; i += 4)
			{
				uint4 samples = loadSample4(i);
				for (uint u = 0; u < 4; u++)
				{
					if (i + u < BlurConstants.SampleCount)
					{
						Sample unpackedSample = unpackSample(samples[u]);

						// Y axis doesn't have the blur radius bump since we want to start at the very top of our box.
						uint cacheIndex = toHorizontalCacheIndex(readIndex + int2(unpackedSample.Offset.x, 0));
						blur += HorizontalCache[cacheIndex] * unpackedSample.Weight;
					}
				}
			}

			uint2 cache2dWrite = uint2(threadGroupId.x, threadGroupId.y + yChunk + slidingWindowReadOffset);
			uint cacheWriteIndex = toVerticalCacheIndex(cache2dWrite);
			VerticalCache[cacheWriteIndex] = (CacheFormat)blur;
		}
	}
}

void simpleHorizontalBlurPass(uint2 loadThreadId, uint2 groupId, int loadHeight, int slidingWindowReadOffset)
{
	for (int yChunk = 0; yChunk < InlineSlidingWindowBlurHeight; yChunk += InlineSlidingWindowBlurHeight)
	{
		[branch]
		if (loadThreadId.y + yChunk < loadHeight)
		{
			TexelFormat blur = 0.0f;
			for (uint i = 0; i < BlurConstants.SampleCount; i += 4)
			{
				uint4 samples = loadSample4(i);
				for (uint u = 0; u < 4; u++)
				{
					if (i + u < BlurConstants.SampleCount)
					{
						Sample unpackedSample = unpackSample(samples[u]);

						int2 readIndex = loadThreadId.xy + int2(0, yChunk + slidingWindowReadOffset);
						int2 globalReadIndex = readIndex + int2(groupId.x * InlineSlidingWindowBlurWidth, 0) - GroupSharedOffset;
						globalReadIndex = clamp(globalReadIndex + unpackedSample.Offset,
							int2(0, 0), int2(BlurConstants.SourceWidth - 1, BlurConstants.SourceHeight - 1));

						blur += Source[globalReadIndex] * unpackedSample.Weight;
					}
				}
			}

			uint2 cache2dWrite = loadThreadId.xy + uint2(GroupSharedOffset.x, yChunk + slidingWindowReadOffset);
			uint cacheWriteIndex = toVerticalCacheIndex(cache2dWrite);
			VerticalCache[cacheWriteIndex] = (CacheFormat)blur;
		}
	}
}

void horizontalBlurPass(uint2 loadThreadId, uint2 threadGroupId, uint2 groupId, int loadHeight, int slidingWindowReadOffset)
{
#ifdef HORIZONTAL_GROUPSHARED
	groupSharedHorizontalBlurPass(loadThreadId, threadGroupId, groupId, loadHeight, slidingWindowReadOffset);
#else
	simpleHorizontalBlurPass(loadThreadId, groupId, loadHeight, slidingWindowReadOffset);
#endif
}

[numthreads(InlineSlidingWindowBlurWidth, InlineSlidingWindowBlurHeight, 1)]
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 threadGroupId : SV_GroupThreadID,
	uint3 dispatchId : SV_DispatchThreadID)
{
	// Only load our groupshared with Z curves since that's when we access texture memory.
#ifdef USE_ZCURVE

#if InlineSlidingWindowBlurHeight < InlineSlidingWindowBlurWidth
#error "To use Z Curves - InlineSlidingWindowBlurHeight must be smaller or equal to InlineSlidingWindowBlurWidth"
#endif

	static uint const blockSize = InlineSlidingWindowBlurWidth * InlineSlidingWindowBlurWidth;
	uint subBlockId = threadIndex / blockSize;
	uint subBlockThreadIndex = threadIndex % blockSize;

	uint2 loadThreadId = zCurve(subBlockThreadIndex, InlineSlidingWindowBlurWidth) + uint2(0, subBlockId * InlineSlidingWindowBlurWidth);
#else
	uint2 loadThreadId = threadGroupId.xy;
#endif // USE_ZCURVE

	int groupHeight = BlurConstants.SourceHeight / InlineSlidingWindowBlurHeightGroups;
	int groupStart = groupHeight * groupId.y;
	int groupEnd = groupStart + groupHeight;

	int slidingWindowReadOffset = groupStart;

	// Cache and blur our initial edge condition
	uint preloadHeight = BlurConstants.BlurRadius * 2;
	{
		horizontalBlurPass(loadThreadId, threadGroupId.xy, groupId.xy, preloadHeight, slidingWindowReadOffset);
		slidingWindowReadOffset += preloadHeight;

		// Wait until all our horizontal blurs are done.
		GroupMemoryBarrierWithGroupSync();
	}

	int slidingWindowProcessOffset = groupStart;
	while(slidingWindowProcessOffset < groupEnd)
	{
		// Cache our next texels and do our horizontal blur
		{
			horizontalBlurPass(loadThreadId, threadGroupId.xy, groupId.xy, InlineSlidingWindowBlurHeight, slidingWindowReadOffset);
			slidingWindowReadOffset += InlineSlidingWindowBlurHeight;

			// Wait until all our horizontal blurs are done.
			GroupMemoryBarrierWithGroupSync();
		}

		uint2 writeIndex = uint2(dispatchId.x, threadGroupId.y + slidingWindowProcessOffset);
		[branch]
		if (all(writeIndex < uint2(BlurConstants.SourceWidth, groupEnd)))
		{
			// Do our vertical blur
			int2 readIndex = threadGroupId.xy + int2(0, GroupSharedOffset.y + slidingWindowProcessOffset);
			TexelFormat blur = 0.0f;
			for (uint i = 0; i < BlurConstants.SampleCount; i += 4)
			{
				uint4 samples = loadSample4(i);
				for (uint u = 0; u < 4; u++)
				{
					if (i + u < BlurConstants.SampleCount)
					{
						Sample unpackedSample = unpackSample(samples[u]);

						uint cacheIndex = toVerticalCacheIndex(readIndex + int2(0, unpackedSample.Offset.x)); // flip sample offset
						blur += VerticalCache[cacheIndex] * unpackedSample.Weight;
					}
				}
			}

			Output[writeIndex] = blur;
		}

		slidingWindowProcessOffset += InlineSlidingWindowBlurHeight;
	}
}