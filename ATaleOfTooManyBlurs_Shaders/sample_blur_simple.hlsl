#include "sample_blur.hlsl.h"
#include "sample_blur.hsh"

[numthreads(BlurThreadGroupWidth, BlurThreadGroupWidth, 1)]
void blurCS(
	uint threadIndex : SV_GroupIndex,
	uint2 groupId : SV_GroupID,
	uint3 dispatchId : SV_DispatchThreadID)
{
#ifdef USE_ZCURVE
	dispatchId.xy = zCurve(threadIndex, BlurThreadGroupWidth) + groupId * BlurThreadGroupWidth;
#endif // USE_ZCURVE

	[branch]
	if(any(dispatchId.xy >= uint2(BlurConstants.SourceWidth, BlurConstants.SourceHeight)))
	{
		return;
	} 

	TexelFormat blur = 0.0f;
	for(uint i = 0; i < BlurConstants.SampleCount; i+=4)
	{
		uint4 samples = loadSample4(i);
		for (uint u = 0; u < 4; u++)
		{
			if (i + u < BlurConstants.SampleCount)
			{
				Sample unpackedSample = unpackSample(samples[u]);

				int2 readIndex = clamp((int2)dispatchId.xy + unpackedSample.Offset,
					int2(0, 0), int2(BlurConstants.SourceWidth - 1, BlurConstants.SourceHeight - 1));
				blur += Source[readIndex] * unpackedSample.Weight;
			}
		}
	}

	Output[dispatchId.xy] = blur;
}