// kx_draw.cpp — API de dessin retenue v1, agnostique de backend.
// Tout passe par SkCanvas/SkPaint/SkParagraph/SkCodec — identique raster,
// ganesh et graphite (l'upload texture graphite passe par kx_ctx_graphite_recorder).
#include "kx_skia.h"
#include "kx_internal.h"

#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkRRect.h"
#include "include/core/SkShader.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkTypeface.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkFontStyle.h"
#include "include/core/SkBlurTypes.h"
#include "include/effects/SkGradient.h"
#include "include/codec/SkCodec.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkImageGanesh.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skunicode/include/SkUnicode_icu.h"

#include <vector>
#include <cstring>
#include <limits>

// RGBA wire (0xRRGGBBAA) → SkColor (0xAARRGGBB)
static inline SkColor kx_color(uint32_t rgba) {
    return SkColorSetARGB((rgba & 0xFF), (rgba >> 24) & 0xFF,
                          (rgba >> 16) & 0xFF, (rgba >> 8) & 0xFF);
}

static inline SkCanvas* cv(kx_target* t) {
    if (t && !t->surface && t->onscreen) {
        // onscreen paresseux (metal : drawable par frame) — acquiert à la
        // première écriture ; sur les autres backends c'est un no-op.
        if (kx_acquire_surface(t)) return nullptr;
    }
    return (t && t->surface) ? t->surface->getCanvas() : nullptr;
}

// ---- Paint ------------------------------------------------------------------
struct kx_paint { SkPaint p; };

kx_paint* kx_paint_new(void) {
    auto* q = new kx_paint();
    q->p.setAntiAlias(true);
    return q;
}
void kx_paint_free(kx_paint* q) { delete q; }
void kx_paint_color(kx_paint* q, uint32_t rgba) {
    if (q) { q->p.setShader(nullptr); q->p.setColor(kx_color(rgba)); }
}
void kx_paint_alpha(kx_paint* q, float a01) {
    if (!q) return;
    if (a01 < 0) a01 = 0; if (a01 > 1) a01 = 1;
    q->p.setAlphaf(a01);
}
void kx_paint_style(kx_paint* q, int style) {
    if (!q) return;
    q->p.setStyle(style == 1 ? SkPaint::kStroke_Style
                : style == 2 ? SkPaint::kStrokeAndFill_Style
                : SkPaint::kFill_Style);
}
void kx_paint_stroke_width(kx_paint* q, float w) {
    if (q) q->p.setStrokeWidth(w < 0 ? 0 : w);
}
void kx_paint_blend(kx_paint* q, int blend) {
    if (!q) return;
    if (blend < 0 || blend > (int)SkBlendMode::kLastMode) return;
    q->p.setBlendMode((SkBlendMode)blend);
}
void kx_paint_gradient(kx_paint* q, float x0, float y0, float x1, float y1,
                       const uint32_t* rgba, const float* pos, int n) {
    if (!q || !rgba || n < 2) return;
    std::vector<SkColor4f> cs((size_t)n);
    for (int i = 0; i < n; ++i) cs[i] = SkColor4f::FromColor(kx_color(rgba[i]));
    SkPoint pts[2] = { {x0, y0}, {x1, y1} };
    // API épinglée : SkShaders::LinearGradient(SkGradient{Colors,Interpolation}).
    SkGradient grad(
        SkGradient::Colors(SkSpan<const SkColor4f>(cs.data(), cs.size()),
                           SkSpan<const float>(pos, pos ? (size_t)n : 0),
                           SkTileMode::kClamp),
        SkGradient::Interpolation());
    q->p.setShader(SkShaders::LinearGradient(pts, grad));
}
void kx_paint_blur(kx_paint* q, float sigma) {
    if (!q) return;
    q->p.setMaskFilter(sigma > 0
        ? SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, sigma)
        : nullptr);
}

// ---- Canvas ------------------------------------------------------------------
int kx_canvas_clear(kx_target* t, uint32_t rgba) {
    SkCanvas* c = cv(t); if (!c) return -1;
    c->clear(kx_color(rgba));
    t->dirty = true;
    return 0;
}
int kx_canvas_save(kx_target* t) { SkCanvas* c = cv(t); if (!c) return -1; c->save(); return 0; }
int kx_canvas_restore(kx_target* t) { SkCanvas* c = cv(t); if (!c) return -1; c->restore(); return 0; }
int kx_canvas_save_layer(kx_target* t, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c) return -1;
    c->saveLayer(nullptr, q ? &q->p : nullptr);
    return 0;
}
int kx_canvas_translate(kx_target* t, float dx, float dy) {
    SkCanvas* c = cv(t); if (!c) return -1; c->translate(dx, dy); return 0;
}
int kx_canvas_scale(kx_target* t, float sx, float sy) {
    SkCanvas* c = cv(t); if (!c) return -1; c->scale(sx, sy); return 0;
}
int kx_canvas_rotate(kx_target* t, float deg) {
    SkCanvas* c = cv(t); if (!c) return -1; c->rotate(deg); return 0;
}
int kx_canvas_clip_rect(kx_target* t, float x, float y, float w, float h) {
    SkCanvas* c = cv(t); if (!c) return -1;
    c->clipRect(SkRect::MakeXYWH(x, y, w, h), true);
    return 0;
}
int kx_canvas_clip_rrect(kx_target* t, float x, float y, float w, float h, float rx, float ry) {
    SkCanvas* c = cv(t); if (!c) return -1;
    SkRRect rr = SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h), rx, ry);
    c->clipRRect(rr, true);
    return 0;
}
int kx_canvas_draw_rect(kx_target* t, float x, float y, float w, float h, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !q) return -1;
    c->drawRect(SkRect::MakeXYWH(x, y, w, h), q->p);
    t->dirty = true;
    return 0;
}
int kx_canvas_draw_rrect(kx_target* t, float x, float y, float w, float h,
                         float rx, float ry, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !q) return -1;
    c->drawRRect(SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h), rx, ry), q->p);
    t->dirty = true;
    return 0;
}
int kx_canvas_draw_circle(kx_target* t, float cx, float cy, float r, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !q) return -1;
    c->drawCircle(cx, cy, r, q->p);
    t->dirty = true;
    return 0;
}
int kx_canvas_draw_line(kx_target* t, float x0, float y0, float x1, float y1, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !q) return -1;
    c->drawLine(x0, y0, x1, y1, q->p);
    t->dirty = true;
    return 0;
}

// ---- Texte -------------------------------------------------------------------
namespace tl = skia::textlayout;

struct kx_para {
    tl::ParagraphStyle pstyle;
    std::vector<tl::TextStyle> styles;   // pile courante (push/pop)
    std::vector<std::pair<size_t, tl::TextStyle>> runs; // (len, style)
    std::vector<char> text;
    std::unique_ptr<tl::Paragraph> para;
    kx_fonts* fonts = nullptr;
    bool needs_layout = true;
    float last_width = -1;
};

kx_para* kx_para_new(kx_ctx*, kx_fonts* f) {
    auto* p = new kx_para();
    p->fonts = f;
    p->styles.emplace_back();  // style racine par défaut
    return p;
}
void kx_para_free(kx_para* p) { delete p; }
void kx_para_reset(kx_para* p) {
    if (!p) return;
    p->text.clear(); p->runs.clear(); p->styles.resize(1);
    p->para.reset(); p->needs_layout = true;
}
int kx_para_push_style(kx_para* p, float size, uint32_t rgba, int weight, int font_index) {
    if (!p) return -1;
    tl::TextStyle s = p->styles.back();
    if (size > 0) s.setFontSize(size);
    s.setColor(kx_color(rgba));
    if (weight > 0)
        s.setFontStyle(SkFontStyle(weight, SkFontStyle::kNormal_Width,
                                   SkFontStyle::kUpright_Slant));
    if (font_index >= 0) {
        const auto* fams = kx_fonts_families(p->fonts);
        if (fams && font_index < (int)fams->size())
            s.setFontFamilies({SkString((*fams)[font_index])});
    }
    p->styles.push_back(s);
    return 0;
}
int kx_para_push_style_families(kx_para* p, float size, uint32_t rgba,
                                int weight, const int* indices, int count) {
    if (!p) return -1;
    tl::TextStyle s = p->styles.back();
    if (size > 0) s.setFontSize(size);
    s.setColor(kx_color(rgba));
    if (weight > 0)
        s.setFontStyle(SkFontStyle(weight, SkFontStyle::kNormal_Width,
                                   SkFontStyle::kUpright_Slant));
    const auto* fams = kx_fonts_families(p->fonts);
    if (fams && indices && count > 0) {
        std::vector<SkString> list;
        for (int i = 0; i < count; ++i)
            if (indices[i] >= 0 && indices[i] < (int)fams->size())
                list.push_back((*fams)[indices[i]]);
        if (!list.empty()) s.setFontFamilies(list);
    }
    p->styles.push_back(s);
    return 0;
}
int kx_para_pop_style(kx_para* p) {
    if (!p || p->styles.size() <= 1) return -1;
    p->styles.pop_back();
    return 0;
}
int kx_para_add_text_n(kx_para* p, const char* utf8, size_t len) {
    if (!p || !utf8 || !len) return -1;
    p->runs.emplace_back(len, p->styles.back());
    p->text.insert(p->text.end(), utf8, utf8 + len);
    p->para.reset(); p->needs_layout = true;
    return 0;
}
int kx_para_add_text(kx_para* p, const char* utf8) {
    return kx_para_add_text_n(p, utf8, utf8 ? strlen(utf8) : 0);
}
void kx_para_max_lines(kx_para* p, int n) {
    if (!p) return;
    p->pstyle.setMaxLines(n > 0 ? (size_t)n : std::numeric_limits<size_t>::max());
    p->pstyle.setEllipsis(n > 0 ? u"\u2026" : u"");
    p->para.reset(); p->needs_layout = true;
}
void kx_para_align(kx_para* p, int align) {
    if (!p) return;
    p->pstyle.setTextAlign(align == 1 ? tl::TextAlign::kCenter
                         : align == 2 ? tl::TextAlign::kRight
                         : tl::TextAlign::kStart);
    p->para.reset(); p->needs_layout = true;
}
int kx_para_layout(kx_para* p, float max_width) {
    if (!p || max_width <= 0) return -1;
    if (!p->needs_layout && p->para && p->last_width == max_width) return 0;
    auto fc = kx_fonts_collection(p->fonts);
    if (!fc) return -2;
    auto builder = tl::ParagraphBuilder::make(p->pstyle, sk_ref_sp(fc),
                                              SkUnicodes::ICU::Make());
    size_t off = 0;
    for (auto& r : p->runs) {
        builder->pushStyle(r.second);
        builder->addText(p->text.data() + off, r.first);
        builder->pop();
        off += r.first;
    }
    p->para = builder->Build();
    p->para->layout(max_width);
    p->needs_layout = false;
    p->last_width = max_width;
    return 0;
}
int kx_para_draw(kx_para* p, kx_target* t, float x, float y) {
    SkCanvas* c = cv(t); if (!c || !p || !p->para) return -1;
    p->para->paint(c, x, y);
    t->dirty = true;
    return 0;
}
float kx_para_height(const kx_para* p) {
    return (p && p->para) ? p->para->getHeight() : 0.f;
}
float kx_para_max_intrinsic_width(const kx_para* p) {
    return (p && p->para) ? p->para->getMaxIntrinsicWidth() : 0.f;
}

// ---- Images ------------------------------------------------------------------
struct kx_image {
    sk_sp<SkImage> img;
    int w = 0, h = 0;
};

kx_image* kx_image_decode(kx_ctx* c, const void* data, size_t len) {
    if (!data || !len) return nullptr;
    auto skd = SkData::MakeWithCopy(data, len);
    auto codec = SkCodec::MakeFromData(skd);
    if (!codec) return nullptr;
    SkImageInfo ii = codec->getInfo().makeColorType(kRGBA_8888_SkColorType)
                                    .makeAlphaType(kPremul_SkAlphaType);
    auto bmp = std::make_unique<SkBitmap>();
    if (!bmp->tryAllocPixels(ii)) return nullptr;
    SkCodec::Result r = codec->getPixels(ii, bmp->getPixels(), bmp->rowBytes());
    if (r != SkCodec::kSuccess && r != SkCodec::kIncompleteInput) return nullptr;
    auto raster = bmp->asImage();
    auto* out = new kx_image();
    out->w = ii.width(); out->h = ii.height();
    // Leçon W0 : raster non dessinable sur graphite → upload texture backend.
    if (auto* rec = kx_ctx_graphite_recorder(c)) {
        out->img = SkImages::TextureFromImage(rec, raster.get(), {});
    } else {
        out->img = raster;
    }
    if (!out->img) { delete out; return nullptr; }
    return out;
}
void kx_image_size(const kx_image* im, int* w, int* h) {
    if (w) *w = im ? im->w : 0;
    if (h) *h = im ? im->h : 0;
}
void kx_image_free(kx_ctx*, kx_image* im) { delete im; }

int kx_canvas_draw_image(kx_target* t, const kx_image* im,
                         float x, float y, float w, float h, float a01) {
    SkCanvas* c = cv(t); if (!c || !im || !im->img) return -1;
    SkPaint p;
    if (a01 < 0) a01 = 0; if (a01 > 1) a01 = 1;
    p.setAlphaf(a01);
    SkSamplingOptions samp(SkFilterMode::kLinear);
    c->drawImageRect(im->img.get(),
                     SkRect::MakeXYWH(x, y, w, h), samp, &p);
    t->dirty = true;
    return 0;
}

// ===========================================================================
// kx_draw v2 — paths, ombres, gradients supplémentaires, nine-slice.
// ===========================================================================
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/utils/SkShadowUtils.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/effects/SkImageFilters.h"
#include "include/core/SkImageFilter.h"

static SkGradient make_gradient(const uint32_t* rgba, const float* pos, int n,
                                std::vector<SkColor4f>& cs) {
    cs.resize((size_t)n);
    for (int i = 0; i < n; ++i) cs[i] = SkColor4f::FromColor(kx_color(rgba[i]));
    return SkGradient(
        SkGradient::Colors(SkSpan<const SkColor4f>(cs.data(), cs.size()),
                           SkSpan<const float>(pos, pos ? (size_t)n : 0),
                           SkTileMode::kClamp),
        SkGradient::Interpolation());
}

void kx_paint_gradient_radial(kx_paint* q, float cx, float cy, float r,
                              const uint32_t* rgba, const float* pos, int n) {
    if (!q || !rgba || n < 2 || r <= 0) return;
    std::vector<SkColor4f> cs;
    q->p.setShader(SkShaders::RadialGradient({cx, cy}, r, make_gradient(rgba, pos, n, cs)));
}

void kx_paint_gradient_sweep(kx_paint* q, float cx, float cy, float start_deg,
                             float end_deg, const uint32_t* rgba,
                             const float* pos, int n) {
    if (!q || !rgba || n < 2) return;
    std::vector<SkColor4f> cs;
    q->p.setShader(SkShaders::SweepGradient({cx, cy}, start_deg, end_deg,
                                            make_gradient(rgba, pos, n, cs), nullptr));
}

void kx_paint_stroke_cap(kx_paint* q, int cap) {
    if (!q) return;
    q->p.setStrokeCap(cap == 1 ? SkPaint::kRound_Cap
                    : cap == 2 ? SkPaint::kSquare_Cap
                    : SkPaint::kButt_Cap);
}
void kx_paint_stroke_join(kx_paint* q, int join) {
    if (!q) return;
    q->p.setStrokeJoin(join == 1 ? SkPaint::kRound_Join
                     : join == 2 ? SkPaint::kBevel_Join
                     : SkPaint::kMiter_Join);
}
void kx_paint_stroke_miter(kx_paint* q, float m) {
    if (q) q->p.setStrokeMiter(m < 0 ? 0 : m);
}
void kx_paint_dash(kx_paint* q, float on, float off) {
    if (!q) return;
    if (on <= 0 || off <= 0) { q->p.setPathEffect(nullptr); return; }
    float intervals[2] = {on, off};
    q->p.setPathEffect(SkDashPathEffect::Make(SkSpan<const float>(intervals, 2), 0));
}
void kx_paint_image_filter_blur(kx_paint* q, float sigma) {
    if (!q) return;
    q->p.setImageFilter(sigma > 0
        ? SkImageFilters::Blur(sigma, sigma, SkTileMode::kDecal, nullptr)
        : nullptr);
}

int kx_canvas_save_layer_backdrop(kx_target* t, float x, float y, float w, float h,
                                  float blur_sigma) {
    // Glass : fBackdrop = copie FILTRÉE du contenu déjà dessiné sous les bounds
    // (mécanisme du BackdropFilter de Flutter). Dessiner ensuite dans le layer
    // un panneau translucide → effet verre dépoli au restore.
    SkCanvas* c = cv(t); if (!c) return -1;
    if (w <= 0 || h <= 0) return -2;
    SkRect bounds = SkRect::MakeXYWH(x, y, w, h);
    sk_sp<SkImageFilter> backdrop =
        blur_sigma > 0
            ? sk_sp<SkImageFilter>(SkImageFilters::Blur(blur_sigma, blur_sigma,
                                                      SkTileMode::kDecal, nullptr))
            : nullptr;
    SkCanvas::SaveLayerRec rec(&bounds, nullptr, backdrop.get(), /*flags*/ 0);
    c->saveLayer(rec);
    t->dirty = true;
    return 0;
}


// ---- Path ------------------------------------------------------------------
// Pin 8643b1d6 : SkPath est immutable — tout mutateur vit sur SkPathBuilder
// (snapshot() produit un SkPath réutilisable à chaque frame, sans consommer).
struct kx_path { SkPathBuilder b; };

kx_path* kx_path_new(void) { return new kx_path(); }
void kx_path_free(kx_path* p) { delete p; }
void kx_path_reset(kx_path* p) { if (p) p->b.reset(); }
void kx_path_move_to(kx_path* p, float x, float y) { if (p) p->b.moveTo(x, y); }
void kx_path_line_to(kx_path* p, float x, float y) { if (p) p->b.lineTo(x, y); }
void kx_path_quad_to(kx_path* p, float cx, float cy, float x, float y) {
    if (p) p->b.quadTo(cx, cy, x, y);
}
void kx_path_cubic_to(kx_path* p, float c1x, float c1y, float c2x, float c2y,
                      float x, float y) {
    if (p) p->b.cubicTo(c1x, c1y, c2x, c2y, x, y);
}
void kx_path_conic_to(kx_path* p, float cx, float cy, float x, float y, float w) {
    if (p) p->b.conicTo(cx, cy, x, y, w);
}
void kx_path_arc_to(kx_path* p, float x, float y, float w, float h,
                    float start_deg, float sweep_deg, int force_move) {
    if (!p) return;
    p->b.arcTo(SkRect::MakeXYWH(x, y, w, h), start_deg, sweep_deg, force_move != 0);
}
void kx_path_add_circle(kx_path* p, float cx, float cy, float r) {
    if (p) p->b.addOval(SkRect::MakeLTRB(cx - r, cy - r, cx + r, cy + r));
}
void kx_path_add_rrect(kx_path* p, float x, float y, float w, float h,
                       float rx, float ry) {
    if (p) p->b.addRRect(SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h), rx, ry));
}
void kx_path_close(kx_path* p) { if (p) p->b.close(); }

int kx_canvas_draw_path(kx_target* t, const kx_path* p, const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !p || !q) return -1;
    c->drawPath(p->b.snapshot(), q->p);
    t->dirty = true;
    return 0;
}
int kx_canvas_clip_path(kx_target* t, const kx_path* p) {
    SkCanvas* c = cv(t); if (!c || !p) return -1;
    c->clipPath(p->b.snapshot(), true);
    return 0;
}
int kx_canvas_draw_oval(kx_target* t, float x, float y, float w, float h,
                        const kx_paint* q) {
    SkCanvas* c = cv(t); if (!c || !q) return -1;
    c->drawOval(SkRect::MakeXYWH(x, y, w, h), q->p);
    t->dirty = true;
    return 0;
}

int kx_canvas_draw_shadow(kx_target* t, const kx_path* p, float elev,
                          float light_y, uint32_t ambient, uint32_t spot,
                          int transparent_occ) {
    SkCanvas* c = cv(t); if (!c || !p) return -1;
    // SkShadowUtils : z = hauteur de l'objet au-dessus du plan, lumière à
    // (centre_x, light_y, 600). Flags : transparent occluder ou cadré.
    SkPoint3 z_plane = {0, 0, elev};
    SkPoint3 light = {0, light_y > 0 ? light_y : 600.f, 600.f};
    uint32_t flags = transparent_occ ? SkShadowFlags::kTransparentOccluder_ShadowFlag
                                     : SkShadowFlags::kNone_ShadowFlag;
    SkShadowUtils::DrawShadow(c, p->b.snapshot(), z_plane, light, 600.f,
                              kx_color(ambient), kx_color(spot), flags);
    t->dirty = true;
    return 0;
}

int kx_canvas_draw_image_nine(kx_target* t, const kx_image* im,
                              int cx, int cy, int cw, int ch,
                              float dx, float dy, float dw, float dh, float a01) {
    SkCanvas* c = cv(t); if (!c || !im || !im->img) return -1;
    SkPaint p;
    if (a01 < 0) a01 = 0; if (a01 > 1) a01 = 1;
    p.setAlphaf(a01);
    SkIRect center = SkIRect::MakeXYWH(cx, cy, cw, ch);
    c->drawImageNine(im->img.get(), center,
                     SkRect::MakeXYWH(dx, dy, dw, dh),
                     SkFilterMode::kLinear, &p);
    t->dirty = true;
    return 0;
}
