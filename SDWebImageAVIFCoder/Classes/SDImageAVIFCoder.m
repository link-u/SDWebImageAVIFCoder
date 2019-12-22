//
//  SDImageAVIFCoder.m
//  SDWebImageHEIFCoder
//
//  Created by lizhuoli on 2018/5/8.
//

#import "SDImageAVIFCoder.h"
#import <Accelerate/Accelerate.h>
#if __has_include(<libavif/avif.h>)
#import <libavif/avif.h>
#else
#import "avif.h"
#endif

// Convert 8/10/12bit AVIF image into RGBA8888
static void ConvertAvifImagePlanarToRGB(avifImage * avif, uint8_t * outPixels) {
    vImage_Error err = kvImageNoError;
    BOOL hasAlpha = avif->alphaPlane != NULL;
    size_t components = hasAlpha ? 4 : 3;

    vImage_Buffer outBuffer = {
        .data = outPixels,
        .width = avif->width,
        .height = avif->height,
        .rowBytes = avif->width * components,
    };

    avifReformatState state;
    avifPrepareReformatState(avif, &state);

    vImage_Buffer origY = {
        .data = avif->yuvPlanes[AVIF_CHAN_Y],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_Y],
        .width = avif->width,
        .height = avif->height,
    };
    vImage_Buffer origCb = {
        .data = avif->yuvPlanes[AVIF_CHAN_U],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_U],
        .width = avif->width >> state.formatInfo.chromaShiftX,
        .height = avif->height >> state.formatInfo.chromaShiftY,
    };
    vImage_Buffer origCr = {
        .data = avif->yuvPlanes[AVIF_CHAN_V],
        .rowBytes = avif->yuvRowBytes[AVIF_CHAN_V],
        .width = avif->width >> state.formatInfo.chromaShiftX,
        .height = avif->height >> state.formatInfo.chromaShiftY,
    };
        
    vImage_YpCbCrToARGBMatrix matrix = {0};
    matrix.Yp = 1.0f;
    matrix.Cr_R = 2.0f * (1.0f - state.kr);
    matrix.Cb_B = 2.0f * (1.0f - state.kb);
    matrix.Cb_G = -2.0f * (1.0f - state.kr) * state.kr / state.kg;
    matrix.Cr_G = -2.0f * (1.0f - state.kb) * state.kb / state.kg;
    
    vImage_YpCbCrPixelRange pixelRange = {0};
    switch (avif->depth) {
        case 8:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange.Yp_bias = 16;
                pixelRange.YpRangeMax = 235;
                pixelRange.YpMax = 255;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 128;
                pixelRange.CbCrRangeMax = 240;
                pixelRange.CbCrMax = 255;
                pixelRange.CbCrMin = 0;
            }else{
                pixelRange.Yp_bias = 0;
                pixelRange.YpRangeMax = 255;
                pixelRange.YpMax = 255;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 128;
                pixelRange.CbCrRangeMax = 255;
                pixelRange.CbCrMax = 255;
                pixelRange.CbCrMin = 0;
            }
            break;
        case 10:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange.Yp_bias = 64;
                pixelRange.YpRangeMax = 940;
                pixelRange.YpMax = 1023;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 512;
                pixelRange.CbCrRangeMax = 960;
                pixelRange.CbCrMax = 1023;
                pixelRange.CbCrMin = 0;
            }else{
                pixelRange.Yp_bias = 0;
                pixelRange.YpRangeMax = 1023;
                pixelRange.YpMax = 1023;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 512;
                pixelRange.CbCrRangeMax = 1023;
                pixelRange.CbCrMax = 1023;
                pixelRange.CbCrMin = 0;
            }
            break;
        case 12:
            if (avif->yuvRange == AVIF_RANGE_LIMITED) {
                pixelRange.Yp_bias = 256;
                pixelRange.YpRangeMax = 3760;
                pixelRange.YpMax = 4095;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 2048;
                pixelRange.CbCrRangeMax = 3840;
                pixelRange.CbCrMax = 4095;
                pixelRange.CbCrMin = 0;
            }else{
                pixelRange.Yp_bias = 0;
                pixelRange.YpRangeMax = 4095;
                pixelRange.YpMax = 4095;
                pixelRange.YpMin = 0;
                pixelRange.CbCr_bias = 2048;
                pixelRange.CbCrRangeMax = 4095;
                pixelRange.CbCrMax = 4095;
                pixelRange.CbCrMin = 0;
            }
            break;
        default:
            NSLog(@"Unknown bit depth: %d", avif->depth);
    }
    
    vImage_YpCbCrToARGB convInfo = {0};
    
    // There is a optimized version for 8bit420 -> ARGB8888
    if (avif->depth == 8 && avif->yuvFormat == AVIF_PIXEL_FORMAT_YUV420) {
        err =
        vImageConvert_YpCbCrToARGB_GenerateConversion(&matrix,
                                                      &pixelRange,
                                                      &convInfo,
                                                      kvImage420Yp8_Cb8_Cr8,
                                                      kvImageARGB8888,
                                                      kvImageNoFlags);
        if(err != kvImageNoError) {
            NSLog(@"Failed to setup conversion: %ld", err);
            return;
        }
                
        uint8_t const permuteMap[4] = {1, 2, 3, 0};
        
        if(hasAlpha) {
            err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&origY,
                                                         &origCb,
                                                         &origCr,
                                                         &outBuffer,
                                                         &convInfo,
                                                         permuteMap,
                                                         1.0f,
                                                         kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert to RGBA8888: %ld", err);
                return;
            }
            vImage_Buffer alpha = {
                .data = avif->alphaPlane,
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->alphaRowBytes,
            };
            err = vImageOverwriteChannels_ARGB8888(&alpha, &outBuffer, &outBuffer, 0x1, kvImageNoFlags);
        }else{
            vImage_Buffer tmpBuffer = {
                .data = calloc(avif->width * avif->height * 4, sizeof(uint8_t)),
                .width = avif->width,
                .height = avif->height,
                .rowBytes = avif->width * 4,
            };
            if(!tmpBuffer.data){
                return;
            }
            err = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&origY,
                                                         &origCb,
                                                         &origCr,
                                                         &tmpBuffer,
                                                         &convInfo,
                                                         permuteMap,
                                                         1.0f,
                                                         kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert to RGBA8888: %ld", err);
                free(tmpBuffer.data);
                return;
            }
            err = vImageConvert_RGBA8888toRGB888(&tmpBuffer, &outBuffer, kvImageNoFlags);
            if(err != kvImageNoError) {
                NSLog(@"Failed to convert to RGB888: %ld", err);
            }
            free(tmpBuffer.data);
        }
        return;
    }
}

static void FillRGBABufferWithAVIFImage(vImage_Buffer *red, vImage_Buffer *green, vImage_Buffer *blue, vImage_Buffer *alpha, avifImage *img) {
    red->width = img->width;
    red->height = img->height;
    red->data = img->rgbPlanes[AVIF_CHAN_R];
    red->rowBytes = img->rgbRowBytes[AVIF_CHAN_R];
    
    green->width = img->width;
    green->height = img->height;
    green->data = img->rgbPlanes[AVIF_CHAN_G];
    green->rowBytes = img->rgbRowBytes[AVIF_CHAN_G];
    
    blue->width = img->width;
    blue->height = img->height;
    blue->data = img->rgbPlanes[AVIF_CHAN_B];
    blue->rowBytes = img->rgbRowBytes[AVIF_CHAN_B];
    
    if (img->alphaPlane != NULL) {
        alpha->width = img->width;
        alpha->height = img->height;
        alpha->data = img->alphaPlane;
        alpha->rowBytes = img->alphaRowBytes;
    }
}

static void FreeImageData(void *info, const void *data, size_t size) {
    free((void *)data);
}

@implementation SDImageAVIFCoder

+ (instancetype)sharedCoder {
    static SDImageAVIFCoder *coder;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coder = [[SDImageAVIFCoder alloc] init];
    });
    return coder;
}

- (BOOL)canDecodeFromData:(NSData *)data {
    return [[self class] isAVIFFormatForData:data];
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(SDImageCoderOptions *)options {
    if (!data) {
        return nil;
    }
    CGFloat scale = 1;
    if ([options valueForKey:SDImageCoderDecodeScaleFactor]) {
        scale = [[options valueForKey:SDImageCoderDecodeScaleFactor] doubleValue];
        if (scale < 1) {
            scale = 1;
        }
    }
    
    // Currently only support primary image :)
    CGImageRef imageRef = [self sd_createAVIFImageWithData:data];
    if (!imageRef) {
        return nil;
    }
    
#if SD_MAC
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#else
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#endif
    CGImageRelease(imageRef);
    
    return image;
}

- (nullable CGImageRef)sd_createAVIFImageWithData:(nonnull NSData *)data CF_RETURNS_RETAINED {
    // Decode it
    avifROData rawData = {
        .data = (uint8_t *)data.bytes,
        .size = data.length
    };
    avifImage * avif = avifImageCreateEmpty();
    avifDecoder *decoder = avifDecoderCreate();
    avifResult result = avifDecoderRead(decoder, avif, &rawData);
    if (result != AVIF_RESULT_OK) {
        avifDecoderDestroy(decoder);
        avifImageDestroy(avif);
        return nil;
    }
    
    int width = avif->width;
    int height = avif->height;
    BOOL hasAlpha = avif->alphaPlane != NULL;
    size_t components = hasAlpha ? 4 : 3;
    size_t bitsPerComponent = 8;
    size_t bitsPerPixel = components * bitsPerComponent;
    size_t rowBytes = width * bitsPerPixel / 8;
    
    uint8_t * dest = calloc(width * components * height, sizeof(uint8_t));
    if (!dest) {
        avifDecoderDestroy(decoder);
        avifImageDestroy(avif);
        return nil;
    }
    // convert planar to RGB888/RGBA8888
    ConvertAvifImagePlanarToRGB(avif, dest);
    
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, dest, rowBytes * height, FreeImageData);
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedLast : kCGImageAlphaNone;
    CGColorSpaceRef colorSpaceRef = [SDImageCoderHelper colorSpaceGetDeviceRGB];
    CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;
    CGImageRef imageRef = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, rowBytes, colorSpaceRef, bitmapInfo, provider, NULL, NO, renderingIntent);
    
    // clean up
    CGDataProviderRelease(provider);
    avifDecoderDestroy(decoder);
    avifImageDestroy(avif);
    
    return imageRef;
}

// The AVIF encoding seems slow at the current time, but at least works
- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    return format == SDImageFormatAVIF;
}

- (nullable NSData *)encodedDataWithImage:(nullable UIImage *)image format:(SDImageFormat)format options:(nullable SDImageCoderOptions *)options {
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) {
        return nil;
    }
    
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
    size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
    CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
    CGImageAlphaInfo alphaInfo = bitmapInfo & kCGBitmapAlphaInfoMask;
    CGBitmapInfo byteOrderInfo = bitmapInfo & kCGBitmapByteOrderMask;
    BOOL hasAlpha = !(alphaInfo == kCGImageAlphaNone ||
                      alphaInfo == kCGImageAlphaNoneSkipFirst ||
                      alphaInfo == kCGImageAlphaNoneSkipLast);
    BOOL byteOrderNormal = NO;
    switch (byteOrderInfo) {
        case kCGBitmapByteOrderDefault: {
            byteOrderNormal = YES;
        } break;
        case kCGBitmapByteOrder32Little: {
        } break;
        case kCGBitmapByteOrder32Big: {
            byteOrderNormal = YES;
        } break;
        default: break;
    }
    
    vImageConverterRef convertor = NULL;
    vImage_Error v_error = kvImageNoError;
    
    vImage_CGImageFormat srcFormat = {
        .bitsPerComponent = (uint32_t)bitsPerComponent,
        .bitsPerPixel = (uint32_t)bitsPerPixel,
        .colorSpace = CGImageGetColorSpace(imageRef),
        .bitmapInfo = bitmapInfo
    };
    vImage_CGImageFormat destFormat = {
        .bitsPerComponent = 8,
        .bitsPerPixel = hasAlpha ? 32 : 24,
        .colorSpace = [SDImageCoderHelper colorSpaceGetDeviceRGB],
        .bitmapInfo = hasAlpha ? kCGImageAlphaFirst | kCGBitmapByteOrderDefault : kCGImageAlphaNone | kCGBitmapByteOrderDefault // RGB888/ARGB8888 (Non-premultiplied to works for libbpg)
    };
    
    convertor = vImageConverter_CreateWithCGImageFormat(&srcFormat, &destFormat, NULL, kvImageNoFlags, &v_error);
    if (v_error != kvImageNoError) {
        return nil;
    }
    
    vImage_Buffer src;
    v_error = vImageBuffer_InitWithCGImage(&src, &srcFormat, NULL, imageRef, kvImageNoFlags);
    if (v_error != kvImageNoError) {
        return nil;
    }
    vImage_Buffer dest;
    vImageBuffer_Init(&dest, height, width, hasAlpha ? 32 : 24, kvImageNoFlags);
    if (!dest.data) {
        free(src.data);
        return nil;
    }
    
    // Convert input color mode to RGB888/ARGB8888
    v_error = vImageConvert_AnyToAny(convertor, &src, &dest, NULL, kvImageNoFlags);
    free(src.data);
    vImageConverter_Release(convertor);
    if (v_error != kvImageNoError) {
        free(dest.data);
        return nil;
    }
    
    avifPixelFormat avifFormat = AVIF_PIXEL_FORMAT_YUV444;
    enum avifPlanesFlags planesFlags = hasAlpha ? AVIF_PLANES_RGB | AVIF_PLANES_A : AVIF_PLANES_RGB;
    
    avifImage *avif = avifImageCreate((int)width, (int)height, 8, avifFormat);
    if (!avif) {
        free(dest.data);
        return nil;
    }
    avifImageAllocatePlanes(avif, planesFlags);
    
    NSData *iccProfile = (__bridge_transfer NSData *)CGColorSpaceCopyICCProfile([SDImageCoderHelper colorSpaceGetDeviceRGB]);
    
    avifImageSetProfileICC(avif, (uint8_t *)iccProfile.bytes, iccProfile.length);
    
    vImage_Buffer red, green, blue, alpha;
    FillRGBABufferWithAVIFImage(&red, &green, &blue, &alpha, avif);
    
    if (hasAlpha) {
        v_error = vImageConvert_ARGB8888toPlanar8(&dest, &alpha, &red, &green, &blue, kvImageNoFlags);
    } else {
        v_error = vImageConvert_RGB888toPlanar8(&dest, &red, &green, &blue, kvImageNoFlags);
    }
    free(dest.data);
    if (v_error != kvImageNoError) {
        return nil;
    }
    
    double compressionQuality = 1;
    if (options[SDImageCoderEncodeCompressionQuality]) {
        compressionQuality = [options[SDImageCoderEncodeCompressionQuality] doubleValue];
    }
    int rescaledQuality = AVIF_QUANTIZER_WORST_QUALITY - (int)((compressionQuality) * AVIF_QUANTIZER_WORST_QUALITY);
    
    avifRWData raw = AVIF_DATA_EMPTY;
    avifEncoder *encoder = avifEncoderCreate();
    encoder->minQuantizer = rescaledQuality;
    encoder->maxQuantizer = rescaledQuality;
    encoder->maxThreads = 2;
    avifResult result = avifEncoderWrite(encoder, avif, &raw);
    
    if (result != AVIF_RESULT_OK) {
        avifEncoderDestroy(encoder);
        return nil;
    }
    
    NSData *imageData = [NSData dataWithBytes:raw.data length:raw.size];
    free(raw.data);
    avifEncoderDestroy(encoder);
    
    return imageData;
}


#pragma mark - Helper
+ (BOOL)isAVIFFormatForData:(NSData *)data
{
    if (!data) {
        return NO;
    }
    if (data.length >= 12) {
        //....ftypavif ....ftypavis
        NSString *testString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(4, 8)] encoding:NSASCIIStringEncoding];
        if ([testString isEqualToString:@"ftypavif"]
            || [testString isEqualToString:@"ftypavis"]) {
            return YES;
        }
    }
    
    return NO;
}

@end
