// SGLyricsClip.h says what this draws. All text layout and darkening scrims are pre-baked once per cue,
// and moving-artwork compositing uses a single SIMD premultiplied-alpha blend per frame at capped 3:4
// resolution with hardware-scaled decode and immediate mid-encode cancellation.
#import <Accelerate/Accelerate.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreText/CoreText.h>
#import "SGLyricsClip.h"

// The lock screen fills the screen with a 3:4 clip, so a phone's taller screen cuts its sides off: the
// words keep to this middle share of the width. The center of the words sits this far down, clear of
// the clock above and the controls below.
static const CGFloat kColumn = 0.56;
static const CGFloat kCentreY = 0.5;
static const CGFloat kMaxClipWidth = 576;
// The words' size as a share of the width, made smaller down to kSmallest of it while they run taller
// than kTallest of the height.
static const CGFloat kFont = 0.05;
static const CGFloat kSmallest = 0.58;
static const CGFloat kTallest = 0.45;
static const CGFloat kNextAlpha = 0.4;
// A still is one frame held this long; an animated clip breathes once over kLoopSeconds, which is all it
// plays before the lock screen loops it.
static const int32_t kStillSeconds = 2;
static const int32_t kLoopSeconds = 4;
static const int32_t kFPS = 15;
static const CGFloat kBreath = 0.06;
static const CGFloat kMotionDim = 0.26, kBandDim = 0.64, kBandReach = 0.32;
static const CGFloat kShadowAlpha = 0.9, kShadowBlur = 0.15, kMotionNextAlpha = 0.55;
static const double kMotionFPS = 20;

CGSize SGLyricsClipSize(CGFloat pixels) {
    CGFloat width = MAX(floor(pixels / 16) * 16, 16);
    return CGSizeMake(width, round(width * 4 / 3 / 16) * 16);
}

CGSize SGLyricsClipTargetSize(CGFloat screenPixels) {
    return SGLyricsClipSize(MIN(screenPixels, kMaxClipWidth));
}

static CGContextRef newContext(CGSize size, void *data, size_t bytesPerRow) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data, (size_t)size.width, (size_t)size.height, 8, bytesPerRow, space,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    return context;
}

// The width the cover is blurred at, before it is drawn at the clip's size.
static const CGFloat kBackdropWidth = 128;

CGImageRef SGLyricsClipBackdrop(CGImageRef cover, CGSize size) {
    CGContextRef context = newContext(size, NULL, 0);
    CGRect bounds = {CGPointZero, size};
    CGContextSetRGBFillColor(context, 0.11, 0.11, 0.12, 1);
    CGContextFillRect(context, bounds);
    if (cover) {
        static CIContext *renderer;
        static dispatch_once_t once;
        // On the CPU: the lock screen asks while Spotify is in the background, where GPU work gets it killed.
        dispatch_once(&once, ^{ renderer = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @YES}]; });
        CGSize small = CGSizeMake(kBackdropWidth, round(kBackdropWidth * size.height / size.width));
        CIImage *image = [CIImage imageWithCGImage:cover];
        CGFloat scale = MAX(small.width / image.extent.size.width, small.height / image.extent.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation((small.width - image.extent.size.width) / 2,
                                                                                 (small.height - image.extent.size.height) / 2)];
        image = [[image imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:small.width * 0.05];
        CGImageRef blurred = [renderer createCGImage:image fromRect:(CGRect){CGPointZero, small}];
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        if (blurred) CGContextDrawImage(context, bounds, blurred);
        CGImageRelease(blurred);
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.45);
        CGContextFillRect(context, bounds);
    }
    CGImageRef backdrop = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return backdrop;
}

static NSAttributedString *wordsAt(NSString *previous, NSString *line, NSString *next, CGFloat fontSize, CGFloat dimAlpha) {
    CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fontSize, NULL);
    CGFloat blockSpacing = fontSize * 0.55;
    CGFloat coupletSpacing = fontSize * 0.22;
    CTParagraphStyleSetting blockSettings[] = {
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(blockSpacing), &blockSpacing},
    };
    CTParagraphStyleSetting coupletSettings[] = {
        {kCTParagraphStyleSpecifierParagraphSpacingBefore, sizeof(coupletSpacing), &coupletSpacing},
    };
    CTParagraphStyleRef blockParagraph = CTParagraphStyleCreate(blockSettings, 1);
    CTParagraphStyleRef coupletParagraph = CTParagraphStyleCreate(coupletSettings, 1);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat white[] = {1, 1, 1, 1}, dim[] = {1, 1, 1, dimAlpha};
    CGColorRef lit = CGColorCreate(space, white), unlit = CGColorCreate(space, dim);
    NSMutableAttributedString *words = [NSMutableAttributedString new];
    NSString *texts[] = {previous, line, next};
    for (int i = 0; i < 3; i++) {
        if (!texts[i].length) continue;
        NSArray<NSString *> *sublines = (i == 1) ? [texts[i] componentsSeparatedByString:@"\n"] : @[texts[i]];
        for (NSUInteger s = 0; s < sublines.count; s++) {
            if (!sublines[s].length) continue;
            CTParagraphStyleRef para = (i == 1 && s > 0) ? coupletParagraph : blockParagraph;
            NSDictionary *attributes = @{
                (id)kCTFontAttributeName: (__bridge id)font,
                (id)kCTParagraphStyleAttributeName: (__bridge id)para,
                (id)kCTForegroundColorAttributeName: (__bridge id)(i == 1 ? lit : unlit),
            };
            NSString *piece = words.length ? [@"\n" stringByAppendingString:sublines[s]] : sublines[s];
            [words appendAttributedString:[[NSAttributedString alloc] initWithString:piece attributes:attributes]];
        }
    }
    CFRelease(font);
    CFRelease(blockParagraph);
    CFRelease(coupletParagraph);
    CGColorRelease(lit);
    CGColorRelease(unlit);
    CGColorSpaceRelease(space);
    return words;
}

static BOOL drawWordsIntoContext(CGContextRef context, NSString *previous, NSString *line, NSString *next,
                                 CGSize size, BOOL withShadow) {
    if (!previous.length && !line.length && !next.length) return NO;
    CGFloat width = round(size.width * kColumn);
    CGFloat fontSize = size.width * kFont;
    CTFramesetterRef setter = NULL;
    CGSize fits = CGSizeZero;
    for (CGFloat scale = 1; scale >= kSmallest - 0.01; scale -= 0.1) {
        if (setter) CFRelease(setter);
        setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)
            wordsAt(previous, line, next, fontSize * scale, withShadow ? kMotionNextAlpha : kNextAlpha));
        fits = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRangeMake(0, 0), NULL, CGSizeMake(width, CGFLOAT_MAX), NULL);
        if (fits.height <= size.height * kTallest) break;
    }
    CGFloat height = ceil(fits.height) + 1;
    CGRect box = CGRectMake(round((size.width - width) / 2), round(size.height * (1 - kCentreY) - height / 2), width, height);
    CGPathRef path = CGPathCreateWithRect(box, NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, NULL);
    CGContextSaveGState(context);
    if (withShadow) {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat shade[] = {0, 0, 0, kShadowAlpha};
        CGColorRef color = CGColorCreate(space, shade);
        CGContextSetShadowWithColor(context, CGSizeZero, fontSize * kShadowBlur, color);
        CGColorRelease(color);
        CGColorSpaceRelease(space);
    }
    CTFrameDraw(frame, context);
    CGContextRestoreGState(context);
    CFRelease(frame);
    CGPathRelease(path);
    CFRelease(setter);
    return YES;
}

static CGImageRef newWords(NSString *previous, NSString *line, NSString *next, CGSize size) CF_RETURNS_RETAINED {
    if (!previous.length && !line.length && !next.length) return NULL;
    CGContextRef context = newContext(size, NULL, 0);
    drawWordsIntoContext(context, previous, line, next, size, NO);
    CGImageRef words = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return words;
}

static void drawFrame(CGContextRef context, CGImageRef backdrop, CGImageRef words, CGSize size, double phase) {
    CGFloat grow = kBreath * (1 - cos(2 * M_PI * phase)) / 2;
    CGRect bounds = {CGPointZero, size};
    CGContextDrawImage(context, CGRectInset(bounds, -size.width * grow / 2, -size.height * grow / 2), backdrop);
    if (words) CGContextDrawImage(context, bounds, words);
}

CGImageRef SGLyricsClipFrame(CGImageRef backdrop, NSString *line, NSString *next, CGSize size) {
    CGContextRef context = newContext(size, NULL, 0);
    if (backdrop) CGContextDrawImage(context, (CGRect){CGPointZero, size}, backdrop);
    drawWordsIntoContext(context, nil, line, next, size, NO);
    CGImageRef frame = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return frame;
}

BOOL SGLyricsClipWriteImage(NSURL *file, CGImageRef image, CGSize size) {
    if (!image) return NO;
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(1200000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) [NSThread sleepForTimeInterval:0.002];
    CVPixelBufferRef buffer = NULL;
    BOOL ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
        && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
    if (ok) {
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        CGContextDrawImage(context, (CGRect){CGPointZero, size}, image);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:kCMTimeZero];
        CVPixelBufferRelease(buffer);
    }
    if (!ok) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMake(kStillSeconds, 1)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

BOOL SGLyricsClipWrite(NSURL *file, CGImageRef backdrop, NSString *line, NSString *next, CGSize size,
                       SGLyricsClipStyle style, SGLyricsClipCancelBlock cancel) {
    if (cancel && cancel()) return NO;
    if (style == SGLyricsClipStill) {
        CGImageRef frame = SGLyricsClipFrame(backdrop, line, next, size);
        BOOL ok = SGLyricsClipWriteImage(file, frame, size);
        CGImageRelease(frame);
        return ok;
    }
    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    if (!writer) return NO;
    int32_t frames = kLoopSeconds * kFPS;
    CMTime length = CMTimeMake(kLoopSeconds, 1);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(size.width),
        AVVideoHeightKey: @(size.height),
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(1500000), AVVideoMaxKeyFrameIntervalKey: @(kFPS)},
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(size.width),
            (id)kCVPixelBufferHeightKey: @(size.height),
        }];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];
    CGImageRef words = newWords(nil, line, next, size);
    BOOL ok = YES;
    for (int32_t i = 0; i < frames && ok; i++) {
        if (cancel && cancel()) {
            ok = NO;
            break;
        }
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) {
            if (cancel && cancel()) { ok = NO; break; }
            [NSThread sleepForTimeInterval:0.002];
        }
        if (!ok) break;
        CVPixelBufferRef buffer = NULL;
        ok = writer.status == AVAssetWriterStatusWriting && adaptor.pixelBufferPool
            && CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer) == kCVReturnSuccess;
        if (!ok) break;
        CVPixelBufferLockBaseAddress(buffer, 0);
        CGContextRef context = newContext(size, CVPixelBufferGetBaseAddress(buffer), CVPixelBufferGetBytesPerRow(buffer));
        drawFrame(context, backdrop, words, size, (double)i / frames);
        CGContextRelease(context);
        CVPixelBufferUnlockBaseAddress(buffer, 0);
        ok = [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, kFPS)];
        CVPixelBufferRelease(buffer);
    }
    CGImageRelease(words);
    if (!ok) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:length];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

typedef struct {
    CGSize decoded, cut;
    double length;
} Motion;

static AVAssetTrack *motionTrackForFile(NSURL *motionFile, AVURLAsset **outAsset, Motion *outMotion) {
    if (!motionFile) return nil;
    static NSObject *cacheLock;
    static NSString *cachedPath;
    static AVURLAsset *cachedAsset;
    static AVAssetTrack *cachedTrack;
    static Motion cachedMotion;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cacheLock = [NSObject new]; });

    NSString *path = motionFile.path;
    @synchronized (cacheLock) {
        if (cachedTrack && [cachedPath isEqualToString:path]) {
            *outAsset = cachedAsset;
            *outMotion = cachedMotion;
            return cachedTrack;
        }
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:motionFile options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @NO}];
    __block AVAssetTrack *track = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *error) {
        track = tracks.firstObject;
        dispatch_semaphore_signal(loaded);
    }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (!track || !CGAffineTransformIsIdentity(track.preferredTransform)) return nil;

    CGSize raw = CGSizeMake(round(track.naturalSize.width), round(track.naturalSize.height));
    double length = CMTimeGetSeconds(track.timeRange.duration);
    if (raw.width < 16 || raw.height < 16 || !(length > 0)) return nil;

    CGSize rawCut = raw.width / raw.height > 0.75 ? CGSizeMake(raw.height * 0.75, raw.height)
                                                  : CGSizeMake(raw.width, raw.width / 0.75);
    CGFloat scale = rawCut.width > kMaxClipWidth ? kMaxClipWidth / rawCut.width : 1.0;
    CGFloat cutW = MAX(floor(rawCut.width * scale / 16) * 16, 16);
    CGFloat cutH = MAX(floor(cutW * 4 / 3 / 16) * 16, 16);
    CGFloat decW = MAX(floor(raw.width * (cutW / rawCut.width) / 2) * 2, cutW);
    CGFloat decH = MAX(floor(raw.height * (cutH / rawCut.height) / 2) * 2, cutH);
    Motion motion = {CGSizeMake(decW, decH), CGSizeMake(cutW, cutH), length};

    @synchronized (cacheLock) {
        cachedPath = [path copy];
        cachedAsset = asset;
        cachedTrack = track;
        cachedMotion = motion;
    }
    *outAsset = asset;
    *outMotion = motion;
    return track;
}

typedef struct {
    uint8_t *data;
    size_t rowBytes;
} Over;

// Pre-bakes both the vertical readability scrim and the shadowed words into a single premultiplied BGRA8888
// overlay buffer once per lyric cue, reducing per-frame work to one SIMD alpha blend.
static Over makeOver(CGSize cut, NSString *previous, NSString *line, NSString *next) {
    size_t width = (size_t)cut.width, height = (size_t)cut.height, rowBytes = width * 4;
    uint8_t *data = calloc(height, rowBytes);
    if (!data) return (Over){0};
    CGContextRef context = newContext(cut, data, rowBytes);
    BOOL hasWords = previous.length || line.length || next.length;
    if (!hasWords) {
        CGContextSetRGBFillColor(context, 0, 0, 0, kMotionDim);
        CGContextFillRect(context, (CGRect){CGPointZero, cut});
    } else {
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGFloat topEdge = MIN(MAX(1 - kCentreY + kBandReach, 0), 1);
        CGFloat botEdge = MIN(MAX(1 - kCentreY - kBandReach, 0), 1);
        CGFloat midTop = botEdge + (topEdge - botEdge) * 0.72;
        CGFloat midBot = botEdge + (topEdge - botEdge) * 0.28;
        CGFloat stops[] = {0, botEdge, midBot, midTop, topEdge, 1};
        CGFloat colors[] = {
            0, 0, 0, kMotionDim,
            0, 0, 0, kMotionDim,
            0, 0, 0, kBandDim,
            0, 0, 0, kBandDim,
            0, 0, 0, kMotionDim,
            0, 0, 0, kMotionDim,
        };
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, colors, stops, 6);
        CGContextDrawLinearGradient(context, gradient, CGPointMake(0, 0), CGPointMake(0, cut.height), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        drawWordsIntoContext(context, previous, line, next, cut, YES);
    }
    CGContextRelease(context);
    return (Over){data, rowBytes};
}

static void freeOver(Over over) {
    free(over.data);
}

static BOOL blendOver(CVPixelBufferRef srcBuffer, Motion motion, const Over *over, void *dstBase, size_t dstRowBytes) {
    if (!over->data || !dstBase) return NO;
    CVPixelBufferLockBaseAddress(srcBuffer, kCVPixelBufferLock_ReadOnly);
    const uint8_t *srcBase = CVPixelBufferGetBaseAddress(srcBuffer);
    size_t srcRowBytes = CVPixelBufferGetBytesPerRow(srcBuffer);
    size_t srcW = CVPixelBufferGetWidth(srcBuffer), srcH = CVPixelBufferGetHeight(srcBuffer);
    size_t cutW = (size_t)motion.cut.width, cutH = (size_t)motion.cut.height;
    if (!srcBase || CVPixelBufferIsPlanar(srcBuffer)
        || CVPixelBufferGetPixelFormatType(srcBuffer) != kCVPixelFormatType_32BGRA
        || srcW < cutW || srcH < cutH || srcRowBytes < srcW * 4) {
        CVPixelBufferUnlockBaseAddress(srcBuffer, kCVPixelBufferLock_ReadOnly);
        return NO;
    }
    size_t cropX = (srcW - cutW) / 2;
    size_t cropY = (srcH - cutH) / 2;
    const uint8_t *cropPtr = srcBase + cropY * srcRowBytes + cropX * 4;
    vImage_Buffer bottom = {(void *)cropPtr, (vImagePixelCount)cutH, (vImagePixelCount)cutW, srcRowBytes};
    vImage_Buffer top = {over->data, (vImagePixelCount)cutH, (vImagePixelCount)cutW, over->rowBytes};
    vImage_Buffer dest = {dstBase, (vImagePixelCount)cutH, (vImagePixelCount)cutW, dstRowBytes};
    vImage_Error err = vImagePremultipliedAlphaBlend_BGRA8888(&top, &bottom, &dest, kvImageDoNotTile);
    CVPixelBufferUnlockBaseAddress(srcBuffer, kCVPixelBufferLock_ReadOnly);
    return err == kvImageNoError;
}

static BOOL eachFrame(AVURLAsset *asset, AVAssetTrack *track, Motion motion, double from, double seconds,
                      SGLyricsClipCancelBlock cancel, BOOL (^each)(CVPixelBufferRef imageBuffer, CMTime time)) {
    int32_t scale = 600;
    double at = fmod(MAX(from, 0), motion.length), done = 0, due = 0;
    while (seconds - done > 0.01) {
        if (cancel && cancel()) return NO;
        double take = MIN(motion.length - at, seconds - done);
        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(motion.decoded.width),
            (id)kCVPixelBufferHeightKey: @(motion.decoded.height),
        }];
        output.alwaysCopiesSampleData = NO;
        if (!reader || ![reader canAddOutput:output]) return NO;
        [reader addOutput:output];
        reader.timeRange = CMTimeRangeMake(CMTimeMakeWithSeconds(at, scale), CMTimeMakeWithSeconds(take, scale));
        if (![reader startReading]) return NO;
        CMSampleBufferRef sample;
        while ((sample = [output copyNextSampleBuffer])) {
            if (cancel && cancel()) {
                CFRelease(sample);
                [reader cancelReading];
                return NO;
            }
            double pts = done + MAX(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - at, 0);
            CVPixelBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sample);
            BOOL keep = pts >= due - 0.002 && pts < done + take && imageBuffer != NULL;
            if (!keep) {
                CFRelease(sample);
                continue;
            }
            due = due + 1.0 / kMotionFPS < pts ? pts + 0.5 / kMotionFPS : due + 1.0 / kMotionFPS;
            BOOL more = each(imageBuffer, CMTimeMakeWithSeconds(pts, scale));
            CFRelease(sample);
            if (!more) {
                [reader cancelReading];
                return YES;
            }
        }
        if (reader.status != AVAssetReaderStatusCompleted) return NO;
        done += take;
        at = 0;
    }
    return YES;
}

CGImageRef SGLyricsClipMotionFrame(NSURL *motionFile, NSString *previous, NSString *line, NSString *next, double from) {
    AVURLAsset *asset = nil;
    Motion motion;
    AVAssetTrack *track = motionTrackForFile(motionFile, &asset, &motion);
    if (!track) return NULL;
    Over over = makeOver(motion.cut, previous, line, next);
    if (!over.data) return NULL;
    __block CGImageRef frame = NULL;
    eachFrame(asset, track, motion, from, motion.length, nil, ^BOOL(CVPixelBufferRef buffer, CMTime time) {
        CGContextRef context = newContext(motion.cut, NULL, 0);
        void *dst = CGBitmapContextGetData(context);
        size_t dstRowBytes = CGBitmapContextGetBytesPerRow(context);
        if (blendOver(buffer, motion, &over, dst, dstRowBytes)) {
            frame = CGBitmapContextCreateImage(context);
        }
        CGContextRelease(context);
        return NO;
    });
    freeOver(over);
    return frame;
}

BOOL SGLyricsClipWriteOverMotion(NSURL *file, NSURL *motionFile, NSString *previous, NSString *line, NSString *next,
                                 double from, double seconds, SGLyricsClipCancelBlock cancel) {
    if (cancel && cancel()) return NO;
    // Ultra-short rapid cues (< 1.1 s) render a single motion still frame in ~15 ms rather than transcoding
    // dozens of frames that will be replaced immediately.
    if (seconds < 1.1) {
        AVURLAsset *asset = nil;
        Motion motion;
        if (!motionTrackForFile(motionFile, &asset, &motion)) return NO;
        CGImageRef still = SGLyricsClipMotionFrame(motionFile, previous, line, next, from);
        if (!still) return NO;
        BOOL ok = !(cancel && cancel()) && SGLyricsClipWriteImage(file, still, motion.cut);
        CGImageRelease(still);
        return ok;
    }

    AVURLAsset *asset = nil;
    Motion motion;
    AVAssetTrack *track = motionTrackForFile(motionFile, &asset, &motion);
    if (!track) return NO;
    seconds = MIN(seconds, motion.length);

    NSURL *partial = [file URLByAppendingPathExtension:@"partial"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:nil];
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(motion.cut.width),
        AVVideoHeightKey: @(motion.cut.height),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @((NSInteger)(motion.cut.width * motion.cut.height * 2.5)),
            AVVideoMaxKeyFrameIntervalKey: @((NSInteger)kMotionFPS),
        },
    }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
        sourcePixelBufferAttributes:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(motion.cut.width),
            (id)kCVPixelBufferHeightKey: @(motion.cut.height),
        }];
    if (!writer || ![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) return NO;
    [writer startSessionAtSourceTime:kCMTimeZero];

    Over over = makeOver(motion.cut, previous, line, next);
    __block BOOL ok = over.data != NULL, any = NO;
    BOOL read = ok && eachFrame(asset, track, motion, from, seconds, cancel, ^BOOL(CVPixelBufferRef srcBuffer, CMTime time) {
        while (!input.readyForMoreMediaData && writer.status == AVAssetWriterStatusWriting) {
            if (cancel && cancel()) { ok = NO; return NO; }
            [NSThread sleepForTimeInterval:0.002];
        }
        CVPixelBufferRef dstBuffer = NULL;
        if (writer.status != AVAssetWriterStatusWriting || !adaptor.pixelBufferPool
            || CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &dstBuffer) != kCVReturnSuccess) {
            ok = NO;
            return NO;
        }
        CVPixelBufferLockBaseAddress(dstBuffer, 0);
        BOOL blended = blendOver(srcBuffer, motion, &over, CVPixelBufferGetBaseAddress(dstBuffer), CVPixelBufferGetBytesPerRow(dstBuffer));
        CVPixelBufferUnlockBaseAddress(dstBuffer, 0);
        if (!blended) {
            CVPixelBufferRelease(dstBuffer);
            ok = NO;
            return NO;
        }
        ok = [adaptor appendPixelBuffer:dstBuffer withPresentationTime:time];
        CVPixelBufferRelease(dstBuffer);
        any = ok || any;
        return ok;
    });
    freeOver(over);
    if (!read || !ok || !any || (cancel && cancel())) {
        [writer cancelWriting];
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [input markAsFinished];
    [writer endSessionAtSourceTime:CMTimeMakeWithSeconds(seconds, 600)];
    dispatch_semaphore_t written = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(written); }];
    dispatch_semaphore_wait(written, DISPATCH_TIME_FOREVER);
    if (writer.status != AVAssetWriterStatusCompleted) {
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:file error:nil];
    return [NSFileManager.defaultManager moveItemAtURL:partial toURL:file error:nil];
}

NSString *SGLyricsClipLook(NSURL *motion, SGLyricsClipStyle style) {
    if (!motion) return [NSString stringWithFormat:@"%ld", (long)style];
    NSString *name = motion.lastPathComponent.stringByDeletingPathExtension;
    return [NSString stringWithFormat:@"m%@s%ld", name.length > 16 ? [name substringToIndex:16] : name, (long)style];
}
