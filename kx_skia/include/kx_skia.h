// kx_skia — ABI C minimale partagée entre le shim C++ (Skia) et le code Zig.
// Contrat W0, conçu pour être réutilisé tel quel par K0 (natif) et K1.
// Toutes les fonctions renvoient 0/val en succès, négatif en échec, sauf mention contraire.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kx_ctx kx_ctx;
typedef struct kx_target kx_target;
typedef struct kx_fonts kx_fonts;
typedef struct kx_readback kx_readback;

typedef enum kx_backend {
    KX_BACKEND_RASTER = 0,
    KX_BACKEND_GANESH_WEBGL = 1,
    KX_BACKEND_GRAPHITE_WEBGPU = 2,
    KX_BACKEND_GANESH_GL = 3,      // réservé K0 natif
    KX_BACKEND_GRAPHITE_VULKAN = 4,
    KX_BACKEND_GRAPHITE_METAL = 5,
    KX_BACKEND_GRAPHITE_DAWN = 6,  // réservé K0 natif (D3D12/Vulkan/Metal)
} kx_backend;

// ---- Contextes ----------------------------------------------------------
// Le device WebGPU doit avoir été pré-initialisé côté JS dans
// Module['preinitializedWebGPUDevice'] (navigator.gpu.requestAdapter/requestDevice).
kx_ctx* kx_ctx_create_graphite_webgpu(void);
// canvas_selector peut être NULL : contexte offscreen-only (pas de présentation).
kx_ctx* kx_ctx_create_ganesh_webgl(const char* canvas_selector);
kx_ctx* kx_ctx_create_raster(void);
// Natifs (K0) — en wasm renvoient NULL.
kx_ctx* kx_ctx_create_ganesh_gl(void);
/* Variante K1 : utilise le contexte GL déjà courant (SDL/GLFW/platform).
   get_proc = SDL_GL_GetProcAddress ou équivalent. */
typedef void* (*kx_gl_getproc)(const char* name);
kx_ctx* kx_ctx_create_ganesh_gl_current(kx_gl_getproc get_proc);
/* Cible onscreen GL : wrappe le framebuffer 0 (fenêtre). Recréer après resize. */
kx_target* kx_target_onscreen_gl(kx_ctx*, int w, int h);
kx_ctx* kx_ctx_create_graphite_vulkan(void);
/* VkInstance du ctx (backend graphite-vulkan seulement), à passer à
   SDL_Vulkan_CreateSurface pour obtenir le VkSurfaceKHR onscreen.
   NULL hors backend vulkan. */
void* kx_ctx_vk_instance(const kx_ctx*);
kx_ctx* kx_ctx_create_graphite_metal(void);
kx_ctx* kx_ctx_create_graphite_dawn(void);
kx_ctx* kx_ctx_create_graphite_dawn_d3d12(void);
kx_ctx* kx_ctx_create_graphite_dawn_vulkan(void);
/* Cible onscreen Dawn/WebGPU : swapchain sur le handle natif
   (HWND Windows, CAMetalLayer macOS, ANativeWindow Android).
   Recreer apres resize. */
kx_target* kx_target_onscreen_dawn(kx_ctx*, void* native_handle, int w, int h);
/* Cible onscreen graphite-vulkan : swapchain sur un VkSurfaceKHR créé par
   l'hôte (SDL_Vulkan_CreateSurface). Le ctx adopte la surface passée
   (détruite dans kx_ctx_free) ; vk_surface=NULL réutilise celle du ctx
   (recréation au resize). Recréer après resize. */
kx_target* kx_target_onscreen_vulkan(kx_ctx*, void* vk_surface, int w, int h);
/* Cible onscreen Metal (macOS/iOS) : CAMetalLayer — drawable acquis par frame,
   scale = contentsScale (<=0 : valeur courante du layer). */
kx_target* kx_target_onscreen_metal(kx_ctx*, void* ca_metal_layer, int w, int h, double scale);
kx_backend kx_ctx_backend(const kx_ctx*);
// Chaîne descriptive backend+driver pour BenchResult (ne pas libérer).
const char* kx_ctx_driver_info(const kx_ctx*);
// 1 si le contexte a du travail GPU non terminé (graphite non-yielding).
int kx_ctx_has_unfinished_work(kx_ctx*);
void kx_ctx_free(kx_ctx*);

// ---- Cibles de rendu -----------------------------------------------------
kx_target* kx_target_offscreen(kx_ctx*, int w, int h);
// Cible canvas présentable (graphite-webgpu seulement pour l'instant).
kx_target* kx_target_canvas(kx_ctx*, const char* canvas_selector, int w, int h);
void kx_target_free(kx_target*);
void kx_target_size(const kx_target*, int* w, int* h);

// ---- Accessibilité (macOS : NSAccessibility sur le NSView hôte ; K2) -------
// Cycle : begin(view, scale) → item() ×N (parents avant enfants, strings
// UTF-8 COPIÉES côté shim) → end(). `ident` = clé stable (SemItem.node*),
// parent_ident=0 → enfant direct de la vue. Bounds en px physiques → le shim
// divise par scale (drawable_px/logical_pt) et applique flip-Y.
// end() retourne 1 si l'arbre a muté (AXLayoutChanged posté) ; poste aussi
// AXFocusedUIElementChanged quand l'élément focused change.
// Main-thread only. Impl : kx_a11y.mm (Apple only ; hors-Apple = stubs no-op).
typedef enum kx_a11y_role {
    KX_A11Y_GENERIC = 0,
    KX_A11Y_BUTTON = 1,
    KX_A11Y_CHECKBOX = 2,
    KX_A11Y_SLIDER = 3,
    KX_A11Y_TEXTFIELD = 4,
    KX_A11Y_LIST = 5,
    KX_A11Y_LISTITEM = 6,
    KX_A11Y_HEADING = 7,
    KX_A11Y_GROUP = 8,
} kx_a11y_role;
enum {
    KX_A11Y_DISABLED = 1,
    KX_A11Y_FOCUSABLE = 2,
    KX_A11Y_FOCUSED = 4,
    KX_A11Y_SELECTED = 8,
};
int  kx_a11y_sync_begin(void* nsview, double scale);
int  kx_a11y_sync_item(void* nsview, void* ident, void* parent_ident,
                       int role, const char* label, const char* hint,
                       double x, double y, double w, double h, unsigned flags);
int  kx_a11y_sync_end(void* nsview);
void kx_a11y_clear(void* nsview);
/* accessibilityHitTest sur la vue : retourne 1 si installé (class_addMethod),
   0 si la classe implémentait déjà (swizzle refusé), -1 vue null. Idempotent. */
int  kx_a11y_install_hittest(void* nsview);

/// Callback d'activation par la techno d'assistance : appelé sur le main
/// thread quand l'AT invoque l'action par défaut d'un node exposé.
/// node_ident = le pointeur `ident` passé à sync_item (JAMAIS déréférencé
/// côté shim — c'est la clé opaque du node Zig).
/// action : 0 = press/activate (boutons, checkbox→toggle, listitem→tap) ;
///          1/2 = increment/decrement (slider, optionnel selon plateforme).
/// Enregistré une fois au init ; NULL pour débrancher.
typedef void (*kx_a11y_action_cb)(void* ctx, void* node_ident, int action);
void kx_a11y_set_action_handler(void* nsview, kx_a11y_action_cb cb, void* ctx);

/* Helpers harnais (hors contrat). debug_dump : énumère programmatiquement
   l'arbre AX posé sur la vue (log stderr). activate_ident : appelle le
   path activate de l'élément `ident` (= callback action 0), 1 si appelé. */
void kx_a11y_debug_dump(void* nsview);
int  kx_a11y_activate_ident(void* nsview, void* ident);

/* iOS : 1 quand la UIView SDL est attachée à sa UIWindow — les présents à
   une vue non attachée sont perdus (écran noir persistant). Hors-iOS : 1. */
int kx_ios_window_mapped(void* uiwindow);

// ---- Fonts ---------------------------------------------------------------
kx_fonts* kx_fonts_global(void);
// Ajoute TTF/OTF/TTC ; retourne l'index fonte ou -1. Les données sont copiées.
int kx_fonts_add(kx_fonts*, const void* data, size_t len);
int kx_fonts_count(const kx_fonts*);
/* Charge récursivement tous les .ttf/.otf/.ttc d'un dossier (POSIX) ;
   retourne le nombre de fichiers ajoutés ou -1. */
int kx_fonts_add_dir(kx_fonts*, const char* path);
/* Index famille par nom exact (kia matchFamily) ou -1. */
int kx_fonts_family_index(const kx_fonts*, const char* name);
void kx_fonts_free(kx_fonts*);   // ne pas appeler sur kx_fonts_global()

// ---- Scènes ----------------------------------------------------------------
// 0 = composite W0 (rrect + gradient linéaire + cubique + saveLayer Blur σ4 + paragraphe)
// 1..8 = scènes du corpus 8 scènes (cartes, courbes, gradients, images, flous, clips,
//        paragraphes, pixels). t = phase animée [0,1).
int kx_scene_draw(kx_ctx*, kx_fonts*, kx_target*, int scene, double t);

// Présente une cible canvas (flush + submit + surface.Present).
int kx_present(kx_ctx*, kx_target*);

// ---- Readback asynchrone --------------------------------------------------
// GPU : asyncRescaleAndReadPixels + submit() + checkAsyncWorkCompletion().
// Raster : résolu immédiatement. Appeler kx_readback_poll par frame (rAF).
kx_readback* kx_readback_start(kx_ctx*, kx_target*);
int kx_readback_poll(kx_ctx*, kx_readback*);   // 1 prêt, 0 en attente, <0 échec
// Copie les pixels RGBA premultiplied dans dst (w*h*4) ; retourne octets ou <0.
int kx_readback_copy(const kx_readback*, uint8_t* dst);
// Variante nativa con largo explícito (igual resultado).
int64_t kx_readback_copy_n(const kx_readback*, void* dst, size_t len);
void kx_readback_free(kx_readback*);

// ---- Bench -----------------------------------------------------------------
// Dessine la scène iters fois + submit/flush, retourne le temps CPU ms total.
// Ne garantit PAS la complétion GPU (non-yielding) : c'est le temps record+submit
// CPU, la métrique du corpus.
double kx_bench_ms(kx_ctx*, kx_fonts*, kx_target*, int scene, int iters);

// ===========================================================================
// kx_draw v1 — API de dessin retenue (objets opaques).
// Les scènes corpus ci-dessus restent disponibles pour les tests/goldens.
// Couleurs : uint32 0xRRGGBBAA (RGBA dans l'ordre mémoire du flux).
// ===========================================================================
typedef struct kx_paint kx_paint;
typedef struct kx_para  kx_para;
typedef struct kx_image kx_image;

// ---- Paint -----------------------------------------------------------------
kx_paint* kx_paint_new(void);
void kx_paint_free(kx_paint*);
void kx_paint_color(kx_paint*, uint32_t rgba);
void kx_paint_alpha(kx_paint*, float a01);
void kx_paint_style(kx_paint*, int style);            // 0 fill, 1 stroke, 2 fill+stroke
void kx_paint_stroke_width(kx_paint*, float w);
void kx_paint_blend(kx_paint*, int blend);            // index SkBlendMode (0=SrcOver)
void kx_paint_gradient(kx_paint*, float x0, float y0, float x1, float y1,
                       const uint32_t* rgba, const float* pos, int n); // n>=2, pos nullable
void kx_paint_blur(kx_paint*, float sigma);           // mask blur σ (0 = off)

// ---- Canvas ----------------------------------------------------------------
int kx_canvas_clear(kx_target*, uint32_t rgba);
int kx_canvas_save(kx_target*);
int kx_canvas_restore(kx_target*);
int kx_canvas_save_layer(kx_target*, const kx_paint*); // paint nullable
/* Glass : layer borné dont le contenu pré-existant (backdrop) est rendu
   flouté (sigma) puis copié dans le layer — dessiner un panneau translucide
   puis kx_canvas_restore. blur_sigma<=0 = layer simple sans flou. */
int kx_canvas_save_layer_backdrop(kx_target*, float x, float y, float w, float h,
                                  float blur_sigma);
int kx_canvas_translate(kx_target*, float dx, float dy);
int kx_canvas_scale(kx_target*, float sx, float sy);
int kx_canvas_rotate(kx_target*, float deg);
int kx_canvas_clip_rect(kx_target*, float x, float y, float w, float h);
int kx_canvas_clip_rrect(kx_target*, float x, float y, float w, float h, float rx, float ry);
int kx_canvas_draw_rect(kx_target*, float x, float y, float w, float h, const kx_paint*);
int kx_canvas_draw_rrect(kx_target*, float x, float y, float w, float h, float rx, float ry, const kx_paint*);
int kx_canvas_draw_circle(kx_target*, float cx, float cy, float r, const kx_paint*);
int kx_canvas_draw_line(kx_target*, float x0, float y0, float x1, float y1, const kx_paint*);
int kx_canvas_draw_image(kx_target*, const kx_image*, float x, float y, float w, float h, float a01);

// ---- Texte (paragraphes retenus — layout caché, cf. leçon F0 s2) -------------
// Un kx_para retient ses runs + son layout : le redraw par frame est bon marché,
// ne relayout que quand le contenu/style/largeur change.
kx_para* kx_para_new(kx_ctx*, kx_fonts*);
void  kx_para_free(kx_para*);
void  kx_para_reset(kx_para*);                        // vide les runs, garde l'objet
int   kx_para_push_style(kx_para*, float size, uint32_t rgba, int weight, int font_index);
/* Variante liste ordonnée (CSS-like) : indices famille dans l'ordre de
   préférence, le reste en fallback couverture. count<=0 = style inchangé. */
int   kx_para_push_style_families(kx_para*, float size, uint32_t rgba,
                                  int weight, const int* indices, int count);
int   kx_para_pop_style(kx_para*);
int   kx_para_add_text(kx_para*, const char* utf8);   // utf8 NON null-terminé -> kx_para_add_text_n
int   kx_para_add_text_n(kx_para*, const char* utf8, size_t len);
void  kx_para_max_lines(kx_para*, int n);             // 0 = illimité, ellipsis activé
void  kx_para_align(kx_para*, int align);             // 0 gauche 1 centre 2 droite
int   kx_para_layout(kx_para*, float max_width);      // (re)layout — invalide au changement
int   kx_para_draw(kx_para*, kx_target*, float x, float y);
float kx_para_height(const kx_para*);
float kx_para_max_intrinsic_width(const kx_para*);

// ---- Images ------------------------------------------------------------------
// Décode PNG/JPEG/WebP via SkCodec. Sur backend GPU, kx_image_upload convertit
// en texture backend au premier usage (leçon W0 : raster non dessinable sur graphite).
kx_image* kx_image_decode(kx_ctx*, const void* data, size_t len);
void kx_image_size(const kx_image*, int* w, int* h);
void kx_image_free(kx_ctx*, kx_image*);

// ===========================================================================
// kx_draw v2 — paths, ombres, gradients supplémentaires, nine-slice.
// ===========================================================================
typedef struct kx_path kx_path;

// ---- Paint (extensions) ----------------------------------------------------
void kx_paint_gradient_radial(kx_paint*, float cx, float cy, float r,
                              const uint32_t* rgba, const float* pos, int n);
void kx_paint_gradient_sweep(kx_paint*, float cx, float cy, float start_deg,
                             float end_deg, const uint32_t* rgba,
                             const float* pos, int n); // end==360+sweep complet
void kx_paint_stroke_cap(kx_paint*, int cap);          // 0 butt 1 round 2 square
void kx_paint_stroke_join(kx_paint*, int join);        // 0 miter 1 round 2 bevel
void kx_paint_stroke_miter(kx_paint*, float m);
void kx_paint_dash(kx_paint*, float on, float off);    // 0/0 = plein
void kx_paint_image_filter_blur(kx_paint*, float sigma); // blur sur tout le dessin (≠ mask)

// ---- Path ------------------------------------------------------------------
kx_path* kx_path_new(void);
void kx_path_free(kx_path*);
void kx_path_reset(kx_path*);
void kx_path_move_to(kx_path*, float x, float y);
void kx_path_line_to(kx_path*, float x, float y);
void kx_path_quad_to(kx_path*, float cx, float cy, float x, float y);
void kx_path_cubic_to(kx_path*, float c1x, float c1y, float c2x, float c2y, float x, float y);
void kx_path_conic_to(kx_path*, float cx, float cy, float x, float y, float w);
void kx_path_arc_to(kx_path*, float x, float y, float w, float h,
                    float start_deg, float sweep_deg, int force_move); // oval bounds
void kx_path_add_circle(kx_path*, float cx, float cy, float r);
void kx_path_add_rrect(kx_path*, float x, float y, float w, float h, float rx, float ry);
void kx_path_close(kx_path*);

// ---- Canvas (extensions) ---------------------------------------------------
int kx_canvas_draw_path(kx_target*, const kx_path*, const kx_paint*);
int kx_canvas_clip_path(kx_target*, const kx_path*);
int kx_canvas_draw_oval(kx_target*, float x, float y, float w, float h, const kx_paint*);
// Ombre portée d'un path fermé (SkShadowUtils). elev = hauteur z en px,
// light_y = hauteur de la lumière (rayon), alpha_ambient/spot 0-255.
int kx_canvas_draw_shadow(kx_target*, const kx_path*, float elev,
                          float light_y, uint32_t ambient, uint32_t spot,
                          int transparent_occ);
// Nine-slice : centre source (px image) + rect destination.
int kx_canvas_draw_image_nine(kx_target*, const kx_image*,
                              int cx, int cy, int cw, int ch,
                              float dx, float dy, float dw, float dh, float a01);

#ifdef __cplusplus
}
#endif
