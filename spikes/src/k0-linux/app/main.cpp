// main.cpp — driver console K0-linux : bench + MAE + PNG pour chaque backend.
// usage: k0 <raster|gl|vk> <outdir> [fontdir]
#include "../shim/kx_skia.h"

#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkStream.h"
#include "include/encode/SkPngEncoder.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <chrono>

static const int W = 480, H = 800, N_SCENES = 9, BENCH_ITERS = 30;

static std::vector<uint8_t> read_file(const std::string& p) {
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) return {};
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    std::vector<uint8_t> b(n);
    fread(b.data(), 1, n, f);
    fclose(f);
    return b;
}

int main(int argc, char** argv) {
    const char* backend = argc > 1 ? argv[1] : "raster";
    const char* outdir = argc > 2 ? argv[2] : "results";
    const char* fontdir = argc > 3 ? argv[3] : "../w0-graphite-wasm/assets/fonts";

    // fontes
    kx_fonts* fonts = kx_fonts_global();
    const char* font_files[] = {
        "Roboto-Regular.ttf", "NotoNaskhArabic-VF.ttf",
        "NotoSansCJK-VF-subset.otf.ttc", "NotoColorEmoji-Regular.ttf"};
    for (auto f : font_files) {
        std::string p = std::string(fontdir) + "/" + f;
        auto d = read_file(p);
        if (d.empty()) { fprintf(stderr, "fonte absente %s\n", p.c_str()); continue; }
        if (kx_fonts_add(fonts, d.data(), d.size()) < 0)
            fprintf(stderr, "kx_fonts_add échec %s\n", f);
    }
    printf("fonts=%d\n", kx_fonts_count(fonts));

    // contexte raster (référence MAE) toujours + backend testé
    kx_ctx* rctx = kx_ctx_create_raster();
    kx_ctx* gctx = nullptr;
    if (!strcmp(backend, "raster")) gctx = rctx;
    else if (!strcmp(backend, "gl")) gctx = kx_ctx_create_ganesh_gl();
    else if (!strcmp(backend, "vk")) gctx = kx_ctx_create_graphite_vulkan();
    else { fprintf(stderr, "backend inconnu %s\n", backend); return 2; }
    if (!gctx) {
        printf("{\"status\":\"FAIL\",\"driver\":\"%s-unavailable\",\"errors\":[\"ctx_create → null\"]}\n",
               backend);
        return 1;
    }
    kx_target* rt = kx_target_offscreen(rctx, W, H);
    kx_target* gt = backend[0]=='r'&&backend[1]=='a' ? rt : kx_target_offscreen(gctx, W, H);
    if (!rt || !gt) { printf("{\"status\":\"FAIL\",\"errors\":[\"target → null\"]}\n"); return 1; }

    auto t_init = std::chrono::steady_clock::now();

    printf("{\n \"driver\":\"%s\",\n \"fonts\":%d,\n \"scenes\":{\n",
           kx_ctx_driver_info(gctx), kx_fonts_count(fonts));
    int fails = 0;
    for (int s = 0; s < N_SCENES; ++s) {
        if (kx_scene_draw(rctx, fonts, rt, s, 0.0) != 0) { fails++; continue; }
        if (kx_scene_draw(gctx, fonts, gt, s, 0.0) != 0) { fails++; continue; }
        kx_present(gctx, gt);

        auto* rrb = kx_readback_start(rctx, rt);
        auto* grb = kx_readback_start(gctx, gt);
        if (!rrb || !grb || kx_readback_poll(rctx, rrb) != 1
                        || kx_readback_poll(gctx, grb) != 1) {
            fprintf(stderr, "readback KO s%d\n", s); fails++; continue;
        }
        std::vector<uint8_t> rp(W*H*4), gp(W*H*4);
        kx_readback_copy(rrb, rp.data());
        kx_readback_copy(grb, gp.data());
        kx_readback_free(rrb); kx_readback_free(grb);

        uint64_t acc = 0; uint32_t nw_r = 0, nw_g = 0;
        for (size_t i = 0; i < (size_t)W*H*4; i += 4) {
            acc += std::abs((int)rp[i]-(int)gp[i]) + std::abs((int)rp[i+1]-(int)gp[i+1])
                 + std::abs((int)rp[i+2]-(int)gp[i+2]);
            if (rp[i]<250||rp[i+1]<250||rp[i+2]<250) nw_r++;
            if (gp[i]<250||gp[i+1]<250||gp[i+2]<250) nw_g++;
        }
        double mae = (double)acc / (W*H*3);
        double bench = kx_bench_ms(gctx, fonts, gt, s, BENCH_ITERS);
        double rbench = backend[0]=='r' ? bench : kx_bench_ms(rctx, fonts, rt, s, BENCH_ITERS);
        printf("  \"s%d\":{\"mae\":%.4f,\"nw_r\":%u,\"nw_g\":%u,\"bench_ms\":%.3f,"
               "\"raster_bench_ms\":%.3f}%s\n",
               s, mae, nw_r, nw_g, bench, rbench, s+1<N_SCENES?",":"");
        if (nw_g == 0) fails++;  // scène blanche = échec honnête

        if (s == 0) {  // PNG du composite
            sk_sp<SkData> png = SkPngEncoder::Encode(nullptr,
                    SkImages::RasterFromData(
                        SkImageInfo::Make(W,H,kRGBA_8888_SkColorType,
                                          kPremul_SkAlphaType,
                                          SkColorSpace::MakeSRGB()),
                        SkData::MakeWithCopy(gp.data(), gp.size()), W*4).get(),
                    SkPngEncoder::Options{});
            if (png) {
                std::string path = std::string(outdir) + "/k0-linux-" + backend + ".png";
                SkFILEWStream st(path.c_str());
                st.write(png->data(), png->size());
            }
        }
    }
    printf(" },\n \"status\":\"%s\",\n \"first_frame_ms\":%.1f\n}\n",
           fails ? "FAIL" : "PASS",
           std::chrono::duration<double,std::milli>(
               std::chrono::steady_clock::now()-t_init).count());
    fprintf(stderr, "done fails=%d\n", fails);
    return fails ? 1 : 0;
}
