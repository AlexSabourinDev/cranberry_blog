#include "sample_blur.hsh"

#ifdef HORIZONTAL
static uint2 const BlurThreadGroupSize = uint2(OneDimensionalBlurWidth, OneDimensionalBlurHeight);
#else
static uint2 const BlurThreadGroupSize = uint2(OneDimensionalBlurHeight, OneDimensionalBlurWidth);
#endif 
static uint const MaxCacheWidth = OneDimensionalBlurWidth + MaxBlurRadius * 2;

#ifdef HORIZONTAL
static int2 const BlurAxis = int2(1, 0);
#else
static int2 const BlurAxis = int2(0, 1);
#endif

groupshared CacheFormat Texel1DCache[MaxCacheWidth * OneDimensionalBlurHeight];
uint toCacheIndex(int2 readIndex)
{
#ifdef HORIZONTAL
	return readIndex.x * OneDimensionalBlurHeight + readIndex.y;
#else
	return readIndex.y * OneDimensionalBlurHeight + readIndex.x;
#endif
}

void loadGroupShared1DCache(uint2 threadGroupId, uint2 threadGroupOrigin)
{
	uint blurRadius = BlurConstants.BlurRadius;

	int2 loadOrigin = (int2)threadGroupOrigin-BlurAxis*blurRadius;
	uint loadWidth = (OneDimensionalBlurWidth + blurRadius * 2);
	for(uint i = 0; i < loadWidth; i += OneDimensionalBlurWidth)
	{
		uint2 cacheIndex2D = threadGroupId + BlurAxis * i;

#ifdef HORIZONTAL
		bool writeValid = cacheIndex2D.x < loadWidth;
#else
		bool writeValid = cacheIndex2D.y < loadWidth;
#endif // HORIZONTAL

		[branch]
		if(writeValid)
		{
			int2 readIndex = loadOrigin + (int2)cacheIndex2D;
			readIndex = clamp(readIndex,
				int2(0,0), int2(BlurConstants.SourceWidth-1, BlurConstants.SourceHeight-1));

			uint cacheIndex = toCacheIndex(cacheIndex2D);
			Texel1DCache[cacheIndex] = (CacheFormat)Source[readIndex];
		}
	}
}

#ifdef HORIZONTAL
[numthreads(OneDimensionalBlurWidth, OneDimensionalBlurHeight, 1)]
#else
[numthreads(OneDimensionalBlurHeight, OneDimensionalBlurWidth, 1)]
#endif
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 threadGroupId : SV_GroupThreadID,
	uint3 dispatchId : SV_DispatchThreadID)
{
#ifdef USE_ZCURVE

	static uint const blockSize = OneDimensionalBlurHeight * OneDimensionalBlurHeight;
	uint subBlockId = threadIndex / blockSize;
	uint subBlockThreadIndex = threadIndex % blockSize;

	threadGroupId.xy = zCurve(subBlockThreadIndex, OneDimensionalBlurHeight) + BlurAxis * (subBlockId * OneDimensionalBlurHeight);
	dispatchId.xy = threadGroupId.xy + groupId * BlurThreadGroupSize;

#endif // USE_ZCURVE

	loadGroupShared1DCache(threadGroupId.xy, groupId * BlurThreadGroupSize);
	GroupMemoryBarrierWithGroupSync();

	[branch]
	if (any(dispatchId.xy >= uint2(BlurConstants.SourceWidth, BlurConstants.SourceHeight)))
	{
		return;
	}

	TexelFormat blur = 0.0f;

	int2 readIndex = int2(threadGroupId.xy) + BlurAxis*BlurConstants.BlurRadius;
	for(uint i = 0; i < BlurConstants.SampleCount; i += 4)
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
	Output[dispatchId.xy] = blur;
}