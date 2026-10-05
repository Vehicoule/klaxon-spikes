// kx_metal.mm — pont ObjC++ pour le backend Graphite Metal (K0 macOS).
// Tout passe par CFTypeRef : le shim C++ reste compilé en .cpp.

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

extern "C" {

void* kx_mtl_create_device(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    return (void*)CFBridgingRetain(dev);
}

void* kx_mtl_create_queue(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    return (void*)CFBridgingRetain(q);
}

const char* kx_mtl_device_name(void* device) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    return strdup([dev.name UTF8String]);
}

void kx_mtl_release(void* obj) {
    if (obj) CFRelease((CFTypeRef)obj);
}

void* kx_mtl_retain(void* obj) {
    return obj ? (void*)CFRetain((CFTypeRef)obj) : nullptr;
}

// Configure un CAMetalLayer pour la présentation Skia graphite.
// Retourne le layer retenu (CFRetain) pour garder une ref côté C++.
void* kx_mtl_layer_configure(void* layer, void* device, double w, double h,
                             double scale) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    l.device = dev;
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.framebufferOnly = YES;
    l.drawableSize = CGSizeMake(w, h);
    if (scale > 0) l.contentsScale = scale;
    return (void*)CFRetain((CFTypeRef)l);
}

void* kx_mtl_layer_set_drawable_size(void* layer, double w, double h) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    l.drawableSize = CGSizeMake(w, h);
    return layer;
}

void* kx_mtl_layer_next_drawable(void* layer) {
    CAMetalLayer* l = (__bridge CAMetalLayer*)layer;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d) return nullptr;
    return (void*)CFRetain((CFTypeRef)d);  // +1 — libéré après present
}

// .texture est +0 : sa durée de vie suit le drawable (retenu par nous).
void* kx_mtl_drawable_texture(void* drawable) {
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    return (void*)d.texture;
}

void kx_mtl_present_drawable(void* queue, void* drawable) {
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)queue;
    id<CAMetalDrawable> d = (__bridge id<CAMetalDrawable>)drawable;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    cb.label = @"kx-present";
    [cb presentDrawable:d];
    [cb commit];
}

// iOS : la UIWindow SDL existe avant que la VC view y soit attachée ;
// les présents à une vue non attachée sont perdus → gate de warm-up.
int kx_ios_window_mapped(void* uiwindow) {
#if TARGET_OS_IOS
    UIWindow* w = (__bridge UIWindow*)uiwindow;
    if (!w || w.isHidden) return 0;
    UIView* v = w.rootViewController.view;
    return (v && v.window == w) ? 1 : 0;
#else
    (void)uiwindow;
    return 1;
#endif
}

}  // extern "C"
