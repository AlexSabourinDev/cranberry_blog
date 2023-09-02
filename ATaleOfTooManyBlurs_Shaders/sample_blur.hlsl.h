typedef unsigned int uint;

#define BlurThreadGroupWidth 16
#define OneDimensionalBlurWidth 256
#define OneDimensionalBlurHeight 1
#define MaxBlurRadius 10

#define SlidingWindowBlurWidth 256
#define SlidingWindowBlurHeight 2

#define InlineSlidingWindowBlurWidth 16
#define InlineSlidingWindowBlurHeight 16
#define InlineSlidingWindowBlurHeightGroups 8

// #define USE_INLINE_HORIZONTAL_GS

#ifdef USE_INLINE_HORIZONTAL_GS
	#define InlineBlurThreadGroupWidth 16
	#define InlineBlurThreadGroupHeight 16
#else
	#define InlineBlurThreadGroupWidth 2
	#define InlineBlurThreadGroupHeight 128
#endif

#define MaxSamplesPerAxis 128
#define MaxSampleCount (MaxSamplesPerAxis * MaxSamplesPerAxis)

typedef uint PackedBlurSample;
