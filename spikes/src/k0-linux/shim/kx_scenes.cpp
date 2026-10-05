// kx_scenes.cpp — les scènes du protocole de bench partagé W0/K0.
// Scène 0 : composite W0 (rrect + gradient + cubique + blur-saveLayer + paragraphe).
// Scènes 1..8 : corpus 8-scènes — 160 cartes, 80 courbes×6, 96 gradients,
//               96 images, 12 flous σ4, 24 clips, 30 paragraphes, 1024+1024 px.
// Canvas de référence : 480×800 (le corpus). Toutes les scènes travaillent dans
// les dimensions de la cible passée.
#include "kx_internal.h"
#include "kx_skia.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPoint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkTypeface.h"
#include "include/core/SkShader.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/effects/SkGradient.h"
#include "include/effects/SkImageFilters.h"
#include "modules/skparagraph/include/DartTypes.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <cmath>
#include <memory>
#include <vector>

using namespace skia::textlayout;

// FontCollection de kx_fonts (struct dans kx_skia.cpp) — accès interne.
struct kx_fonts;
skia::textlayout::FontCollection* kx_fonts_collection(kx_fonts*);
const std::vector<SkString>* kx_fonts_families(kx_fonts*);

namespace {

constexpr float W = 480.f, H = 800.f;  // référence du corpus

SkColor wheel(int i) {
    // palette déterministe sans RNG
    return SkColorSetARGB(0xFF,
                          (i * 97 + 40) & 0xFF,
                          (i * 57 + 90) & 0xFF,
                          (i * 137 + 20) & 0xFF);
}

void draw_paragraph(SkCanvas* canvas, kx_fonts* fonts, float x, float y, float w,
                    const char* text, float size, SkColor color) {
    if (!fonts) return;
    ParagraphStyle style;
    style.setTextAlign(TextAlign::kLeft);
    TextStyle ts;
    ts.setColor(color);
    ts.setFontSize(size);
    if (auto fams = kx_fonts_families(fonts))
        ts.setFontFamilies(*fams);
    auto pb = ParagraphBuilder::make(style, sk_ref_sp(kx_fonts_collection(fonts)),
                                     SkUnicodes::ICU::Make());
    if (!pb) return;
    pb->pushStyle(ts);
    pb->addText(text);
    auto para = pb->Build();
    para->layout(w);
    para->paint(canvas, x, y);
}



// --------------------------------------------------------------------------
// Scènes corpus
// --------------------------------------------------------------------------

void scene_cards(SkCanvas* c, double t) {
    // 160 cartes arrondies en grille.
    SkPaint p;
    p.setAntiAlias(true);
    const int cols = 8, rows = 20;
    float cw = W / cols, ch = H / rows;
    for (int i = 0; i < cols * rows; ++i) {
        int cx = i % cols, cy = i / cols;
        SkRect r = SkRect::MakeXYWH(cx * cw + 2, cy * ch + 2, cw - 4, ch - 4);
        float rad = 6.f + 4.f * std::sin((float)(i + (int)(t * 60)) * 0.35f);
        p.setColor(wheel(i));
        c->drawRRect(SkRRect::MakeRectXY(r, rad, rad), p);
    }
}

void scene_curves(SkCanvas* c, double t) {
    // 80 chemins de 6 cubiques.
    SkPaint p;
    p.setAntiAlias(true);
    p.setStyle(SkPaint::kStroke_Style);
    p.setStrokeWidth(1.5f);
    for (int i = 0; i < 80; ++i) {
        SkPathBuilder pb;
        float x = 8.f, y = 12.f + i * (H - 24.f) / 80.f;
        pb.moveTo(x, y);
        for (int s = 0; s < 6; ++s) {
            float nx = x + (W - 16.f) / 6.f;
            float sgn = (s & 1) ? 1.f : -1.f;
            pb.cubicTo(x + 18.f, y - sgn * (18.f + 12.f * std::sin(t * 6.28f + i)),
                       nx - 18.f, y + sgn * (18.f + 12.f * std::cos(t * 6.28f + i)),
                       nx, y);
            x = nx;
        }
        p.setColor(wheel(i * 3));
        c->drawPath(pb.detach(), p);
    }
}

void scene_gradients(SkCanvas* c, double t) {
    // 96 rectangles à gradient linéaire.
    const int cols = 8, rows = 12;
    float cw = W / cols, ch = H / rows;
    for (int i = 0; i < cols * rows; ++i) {
        int cx = i % cols, cy = i / cols;
        SkRect r = SkRect::MakeXYWH(cx * cw, cy * ch, cw, ch);
        SkColor cs[2] = {wheel(i), wheel(i + 48)};
        SkColor4f c4[2] = {SkColor4f::FromColor(cs[0]), SkColor4f::FromColor(cs[1])};
        SkPoint pts[2] = {{r.fLeft, r.fTop}, {r.fRight, r.fBottom}};
        SkGradient grad(SkGradient::Colors(c4, SkTileMode::kClamp),
                        SkGradient::Interpolation());
        SkPaint p;
        p.setShader(SkShaders::LinearGradient(pts, grad));
        c->drawRect(r, p);
    }
}

void scene_images(SkCanvas* c, kx_ctx* ctx, double t) {
    // 96 images 64×64 échantillonnées — texture backend-native.
    auto img = kx_ctx_corpus_image(ctx);
    if (!img) return;
    SkSamplingOptions samp(SkFilterMode::kLinear);
    for (int i = 0; i < 96; ++i) {
        int cx = i % 8, cy = i / 8;
        SkRect dst = SkRect::MakeXYWH(cx * (W / 8.f), cy * (H / 12.f), W / 8.f, H / 12.f);
        c->save();
        c->translate((float)(t * 20.0) * ((i & 1) ? 1.f : -1.f), 0);
        c->drawImageRect(img.get(), dst, samp);
        c->restore();
    }
}

void scene_blurs(SkCanvas* c, double t) {
    // 12 saveLayers avec Blur σ4 empilés.
    SkPaint fill;
    fill.setAntiAlias(true);
    for (int i = 0; i < 12; ++i) {
        SkRect r = SkRect::MakeXYWH(10.f + i * 36.f, 100.f + i * 50.f,
                                    W - 40.f - i * 36.f, 46.f);
        SkPaint layer;
        layer.setImageFilter(SkImageFilters::Blur(4.f, 4.f, SkTileMode::kClamp,
                                                  nullptr));
        c->saveLayer(nullptr, &layer);
        fill.setColor(wheel(i * 5));
        c->drawRRect(SkRRect::MakeRectXY(r, 10.f, 10.f), fill);
        c->restore();
    }
}

void scene_clips(SkCanvas* c, double t) {
    // 24 clips (rrect/path) avec contenu dessiné dedans.
    SkPaint p;
    p.setAntiAlias(true);
    for (int i = 0; i < 24; ++i) {
        SkRect r = SkRect::MakeXYWH(20.f + (i % 6) * 72.f, 40.f + (i / 6) * 180.f,
                                    64.f, 160.f);
        c->save();
        c->clipRRect(SkRRect::MakeRectXY(r, 14.f, 14.f), true);
        p.setColor(wheel(i * 7));
        c->drawRect(r, p);
        SkPathBuilder pb;
        pb.moveTo(r.fLeft, r.centerY());
        pb.cubicTo(r.fLeft + 20, r.fTop, r.fRight - 20, r.fBottom,
                   r.fRight, r.centerY());
        p.setColor(wheel(i * 11));
        c->drawPath(pb.detach(), p);
        c->restore();
    }
}

void scene_paragraphs(SkCanvas* c, kx_fonts* fonts, double t) {
    // 30 paragraphes : latin + arabe + CJK + emoji.
    static const char* texts[] = {
        "The quick brown fox éàü jumps over 12345",
        "مرحبا بالعالم — نص عربي للاختبار",
        "こんにちは のテキスト",
        "Emoji 😀👨‍👩‍👧‍👦🎨 mixed with text",
        "Změření českého řádku s diakritikou",
        "السطر الثاني مع أرقام ١٢٣٤٥",
    };
    float y = 8.f;
    for (int i = 0; i < 30; ++i) {
        draw_paragraph(c, fonts, 8.f, y, W - 16.f, texts[i % 6],
                       14.f + (i % 3) * 2.f, wheel(i * 13) | 0xFF000000);
        y += 25.f + (i % 2) * 4.f;
    }
}

void scene_pixels(SkCanvas* c, double t) {
    // Exactement 1024 px rouges + 1024 px bleus.
    SkPaint p;
    p.setAntiAlias(false);
    std::vector<SkPoint> pts;
    pts.reserve(2048);
    for (int i = 0; i < 1024; ++i) {
        int x = i % 32, y = i / 32;
        pts.push_back({x * (W / 32.f) + 4.f, y * (H / 64.f) + 4.f});
    }
    p.setColor(SK_ColorRED);
    p.setStrokeWidth(3.f);
    c->drawPoints(SkCanvas::kPoints_PointMode, pts, p);
    pts.clear();
    for (int i = 0; i < 1024; ++i) {
        int x = i % 32, y = i / 32;
        pts.push_back({x * (W / 32.f) + 4.f, (y + 32) * (H / 64.f) + 4.f});
    }
    p.setColor(SK_ColorBLUE);
    c->drawPoints(SkCanvas::kPoints_PointMode, pts, p);
}

// Composite W0 : rrect + gradient + cubique + blur-saveLayer + paragraphe.
void scene_composite(SkCanvas* c, kx_fonts* fonts, double t) {
    c->clear(SK_ColorWHITE);
    SkPaint p;
    p.setAntiAlias(true);

    SkRRect rr = SkRRect::MakeRectXY(SkRect::MakeXYWH(20, 20, W - 40, 120), 18, 18);
    SkColor cs[3] = {0xFF3A7BD5, 0xFF00D2FF, 0xFF928DAB};
    SkColor4f c4[3] = {SkColor4f::FromColor(cs[0]), SkColor4f::FromColor(cs[1]),
                       SkColor4f::FromColor(cs[2])};
    SkPoint pts[2] = {{20, 20}, {W - 20, 140}};
    SkGradient grad(SkGradient::Colors(c4, SkTileMode::kClamp),
                    SkGradient::Interpolation());
    p.setShader(SkShaders::LinearGradient(pts, grad));
    c->drawRRect(rr, p);
    p.setShader(nullptr);

    SkPathBuilder pb;
    pb.moveTo(20, 400);
    pb.cubicTo(120, 320, 200, 480, 320, 400);
    pb.cubicTo(360, 370, 420, 430, W - 20, 380);
    p.setStyle(SkPaint::kStroke_Style);
    p.setStrokeWidth(6.f);
    p.setColor(0xFFE11D48);
    c->drawPath(pb.detach(), p);

    SkPaint layer;
    layer.setImageFilter(SkImageFilters::Blur(4.f, 4.f, SkTileMode::kClamp, nullptr));
    c->saveLayer(nullptr, &layer);
    p.setStyle(SkPaint::kFill_Style);
    p.setColor(0xFF10B981);
    c->drawCircle(W / 2, 560, 70, p);
    c->restore();

    draw_paragraph(c, fonts, 24, 660, W - 48,
                   "Klaxon W0 — Graphite WebGPU 😀 é — مرحبا", 18.f, SK_ColorBLACK);
}

}  // namespace

int kx_scene_draw(kx_ctx* c, kx_fonts* f, kx_target* t, int scene, double phase) {
    if (!c || !t) return -1;
    if (t->onscreen && kx_ctx_backend(c) == KX_BACKEND_GRAPHITE_WEBGPU && !t->surface) {
        if (kx_graphite_canvas_acquire(t)) return -2;
    }
    SkCanvas* canvas = t->surface ? t->surface->getCanvas() : nullptr;
    if (!canvas) return -3;
    if (scene != 0) canvas->clear(SK_ColorWHITE);
    switch (scene) {
        case 0: scene_composite(canvas, f, phase); break;
        case 1: scene_cards(canvas, phase); break;
        case 2: scene_curves(canvas, phase); break;
        case 3: scene_gradients(canvas, phase); break;
        case 4: scene_images(canvas, c, phase); break;
        case 5: scene_blurs(canvas, phase); break;
        case 6: scene_clips(canvas, phase); break;
        case 7: scene_paragraphs(canvas, f, phase); break;
        case 8: scene_pixels(canvas, phase); break;
        default: return -4;
    }
    t->dirty = true;
    return 0;
}
