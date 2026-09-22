#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <math.h>
#include <stdlib.h>

static unsigned char *Decode(NSData *data, NSInteger *width, NSInteger *height) {
    if (!data) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NULL;
    *width = (NSInteger)CGImageGetWidth(image);
    *height = (NSInteger)CGImageGetHeight(image);
    size_t row = (size_t)(*width) * 4;
    unsigned char *bytes = calloc((size_t)(*height), row);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = bytes ? CGBitmapContextCreate(bytes, (size_t)(*width), (size_t)(*height),
        8, row, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast) : NULL;
    CGColorSpaceRelease(space);
    if (!context) {
        CGImageRelease(image);
        free(bytes);
        return NULL;
    }
    CGContextDrawImage(context, CGRectMake(0, 0, *width, *height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    return bytes;
}

static BOOL HasTransparentPixel(const unsigned char *bytes, NSInteger count) {
    for (NSInteger index = 0; index < count; index++) {
        if (bytes[index * 4 + 3] < 250) return YES;
    }
    return NO;
}

static void ScaleAlpha(unsigned char *pixel, unsigned char alpha) {
    if (pixel[3] == 0 || alpha == pixel[3]) {
        pixel[3] = alpha;
        return;
    }
    double ratio = alpha / (double)pixel[3];
    pixel[0] = (unsigned char)lround(pixel[0] * ratio);
    pixel[1] = (unsigned char)lround(pixel[1] * ratio);
    pixel[2] = (unsigned char)lround(pixel[2] * ratio);
    pixel[3] = alpha;
}

static void RoundCorners(unsigned char *bytes, NSInteger width, NSInteger height) {
    CGFloat radius = MIN(width, height) * 0.06;
    for (NSInteger y = 0; y < height; y++) {
        for (NSInteger x = 0; x < width; x++) {
            CGFloat dx = 0;
            CGFloat dy = 0;
            if (x < radius) dx = radius - ((CGFloat)x + 0.5);
            else if (x >= width - radius) dx = (CGFloat)x + 0.5 - ((CGFloat)width - radius);
            if (y < radius) dy = radius - ((CGFloat)y + 0.5);
            else if (y >= height - radius) dy = (CGFloat)y + 0.5 - ((CGFloat)height - radius);
            CGFloat coverage = 1;
            if (dx > 0 || dy > 0) {
                coverage = radius + 0.75 - hypot(dx, dy);
                if (coverage < 0) coverage = 0;
                if (coverage > 1) coverage = 1;
            }
            unsigned char *pixel = bytes + ((size_t)y * (size_t)width + (size_t)x) * 4;
            ScaleAlpha(pixel, (unsigned char)lround(pixel[3] * coverage));
        }
    }
}

static BOOL WritePNG(unsigned char *bytes, NSInteger width, NSInteger height, NSString *path) {
    size_t row = (size_t)width * 4;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(bytes, (size_t)width, (size_t)height,
        8, row, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return NO;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!image) return NO;
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (!destination) {
        CGImageRelease(image);
        return NO;
    }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return ok;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4) return 64;
        NSInteger originalWidth = 0;
        NSInteger originalHeight = 0;
        NSInteger fittedWidth = 0;
        NSInteger fittedHeight = 0;
        unsigned char *original = Decode([NSData dataWithContentsOfFile:@(argv[1])],
            &originalWidth, &originalHeight);
        unsigned char *fitted = Decode([NSData dataWithContentsOfFile:@(argv[2])],
            &fittedWidth, &fittedHeight);
        if (!fitted) {
            free(original);
            return 1;
        }
        BOOL sameSize = original && originalWidth == fittedWidth && originalHeight == fittedHeight;
        if (sameSize && HasTransparentPixel(original, originalWidth * originalHeight)) {
            NSInteger count = originalWidth * originalHeight;
            for (NSInteger index = 0; index < count; index++)
                ScaleAlpha(fitted + index * 4, original[index * 4 + 3]);
        } else {
            RoundCorners(fitted, fittedWidth, fittedHeight);
        }
        BOOL wrote = WritePNG(fitted, fittedWidth, fittedHeight, @(argv[3]));
        free(original);
        free(fitted);
        return wrote ? 0 : 3;
    }
}
