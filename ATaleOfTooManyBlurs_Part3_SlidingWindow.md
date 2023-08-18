# A Tale Of Too Many Blurs (3/?) - Sliding Window

![](ATaleOfTooManyBlurs_Assets/BluryBlur.png)

In our previous [post](ATaleOfTooManyBlurs_Part2_SeparableKernels.md) - we explored separating our blur kernals instead of doing an `NxN` blur we did an `N+N` blur.

Additionally, we touched on using groupshared memory to reduce our overall memory pressure at the potential cost of some of our occupancy.

In this post, we're going to explore an extension of our separable blur as well as the inline separable blur we introduced in the previous post.

I've observed this blur variant to have consistently high performance characteristics accross a variety of scenarios at the cost of some pretty high code complecity.

This algorithm is not my design - I'm simply describing it in a way that I think I would have found helpful when originally implementing it.

Credit goes to Jordan Logan and Timothy Lottes for presenting the core idea [\[link\]](https://gpuopen.com/gdc-presentations/2019/gdc-2019-s5-blend-of-gcn-optimization-and-color-processing.pdf) that I'm presenting here and Sebastian Aaltonen for describing it on twitter which originally brought the technique to my attention.

Lets jump in!

## The Sliding Window

Lets loop back to our original one dimensional blur with sharing through groupshared.

![](ATaleOfTooManyBlurs_Assets/Sharing_01.png)

![](ATaleOfTooManyBlurs_Assets/Sharing_02.png)

This sharing works really well.

But there's a flaw.

What about the boundaries between threadgroups.

Let's imagine that we have 2x1 threadgroups.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_01.png)

Where red is our first threadgroup and blue is our second threadgroup.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_02.png)

As you can see above, we're actually doing redundant loads across our threadgroups!

One way we can explore resolving this is by implementing a sliding window.

Instead of spawning `X` threadgroups to span the whole of your texture, you would spawn a single threadgroup per-column and this threadgroup would slide from left to right to process your whole texture while using groupshared memory as your intermediate buffer.

So you would start by filling up groupshared with the memory you need for a single invocation of your blur.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_03.png)

You would then work with groupshared to process your blur.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_04.png)

Then you would reload `ThreadGroup` number of elements into groupshared. Evicting the previous values that you won't use anymore.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_05.png)

And you would blur using those values!

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_06.png)

Of course, groupshared can't grow like that.

Instead, you can implement your groupshared buffer as a ring buffer.

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_07.png)

And finally, you scan your threadgroup across the whole texture width!

![](ATaleOfTooManyBlurs_Assets/SlidingWindow.gif)

With this scheme, our one dimensional blur has no wasted texture loads.

But we run into an issue.

Spawning enough threads to hide our remaining texture load latency!

Sebastian Aaltonen went into excellent detail here on how you want to maximize your occupancy, but Twitter is not being particularly friendly to my lack of a Twitter account so I'm going to work through it here again.

If you decide to spawn a square threadgroup of 16x16, then you can easily calculate the number of threads you can spawn for a 4K texture as:

```
TotalThreadCount = ThreadgroupCount * ThreadGroupThreadCount

ThreadgroupCount = TextureHeight/ThreadGroupHeight
ThreadgroupCount = 4096/16
ThreadgroupCount = 256

TotalThreadCount = 256 * 16 * 16
TotalThreadCount = 65536
```

If we look at the Xbox Series X, we have 52 available Compute Unit, each compute unit can track 64 wave32s at once for a total of 106,496 threads in flight.

More threads than what we're spawning!

What you can do instead, is use an asymmetrical threadgroup size.

If we break down the algebra of our total thread count we see that

```
TotalThreadCount = ThreadgroupCount * ThreadGroupThreadWidth * ThreadGroupHeight
ThreadgroupCount = TextureHeight / ThreadGroupHeight

TotalThreadCount = TextureHeight / ThreadGroupHeight * ThreadGroupThreadWidth * ThreadGroupHeight

TotalThreadCount = TextureHeight * ThreadGroupThreadWidth
```

As we can see, our total thread count is entirely dependent on our threadgroup width!

So what we can do is shrink our threadgroup height and lengthen our threadgroup width.

Experimentally, `256x2` provided the best results on my GPU.

A `256x2` threadgroup gives us a total of `4096 * 256 = 1,048,576` threads!

A substantially higher utilization of our GPU and higher performance to boot!

Lets take a look at some numbers.

### Results!

With a threadgroup of `256x2`:

|Width|2D       |Separable|Separable GS|Sliding Window|
|-----|---------|---------|------------|--------------|
|3    |0.735148 |0.821471 |1.013779    |0.957298      |
|5    |1.62365  |0.901881 |1.108324    |1.023394      |
|7    |3.527865 |1.02799  |1.154124    |1.086498      |
|9    |5.391209 |1.214321 |1.200699    |1.168042      |
|11   |8.637562 |1.492953 |1.323388    |1.226717      |
|13   |11.549441|1.702914 |1.466267    |1.300704      |
|15   |16.304226|1.993194 |1.61179     |1.38043       |
|17   |20.257372|2.233709 |1.728423    |1.532896      |
|19   |26.159442|2.549869 |1.901066    |1.647792      |

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_128bpp.png)

As you can see, we consistently beat our groupshared separable variant!

Whereas, if we use a threadgroup size of `16x16` we get:

|Width|2D       |Separable|Separable GS|Sliding Window|
|-----|---------|---------|------------|--------------|
|3    |0.735148 |0.821471 |1.013779    |1.083223      |
|5    |1.62365  |0.901881 |1.108324    |1.194497      |
|7    |3.527865 |1.02799  |1.154124    |1.270294      |
|9    |5.391209 |1.214321 |1.200699    |1.41244       |
|11   |8.637562 |1.492953 |1.323388    |1.547291      |
|13   |11.549441|1.702914 |1.466267    |1.764806      |
|15   |16.304226|1.993194 |1.61179     |1.91566       |
|17   |20.257372|2.233709 |1.728423    |2.149695      |
|19   |26.159442|2.549869 |1.901066    |2.328058      |

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_128bpp.png)

We always lose to our groupshared variant...

It aint easy being a graphics programmer!

### What if I don't have a 4k texture?

If you don't have a 4k texture, you may not need all these blur variants at all!

But if you want to try anyways, with a threadgroup size of `256x2` and a texture size of `1024x1024` we would get an overall thread count of `256 * 1024 = 262,144` which is still decent, but if you want to explore alternatives, you can explore spawning multiple "columns".

![](ATaleOfTooManyBlurs_Assets/SlidingWindow_MultipleColumns.gif)

These columns will double your threadcount at the cost of some extra redundant texture loads at the edges between each column.

(This idea will reappear later)

## Can we do better?

YES!

## Conclusion


See you next time!

## Appendices

### Appendix A

## References

[1] [A Blend Of GCN Optimization And Color Processing](https://gpuopen.com/gdc-presentations/2019/gdc-2019-s5-blend-of-gcn-optimization-and-color-processing.pdf)

[2] [RDNA White Paper](https://www.amd.com/system/files/documents/rdna-whitepaper.pdf)