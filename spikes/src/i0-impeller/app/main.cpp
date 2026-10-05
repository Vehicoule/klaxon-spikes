// i0-impeller : bench Impeller GLES sur corpus fidèle, fenêtre SDL3.
// Mesure par frame : build canvas + aiks->Render + present. JSON out/i0-s*.json
#include <SDL3/SDL.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <memory>
#include <vector>

#include "flutter/fml/mapping.h"
#include "impeller/aiks/aiks_context.h"
#include "impeller/aiks/canvas.h"
#include "impeller/aiks/image.h"
#include "impeller/aiks/paint.h"
#include "impeller/core/sampler_descriptor.h"
#include "impeller/geometry/path_builder.h"
#include "impeller/entity/gles/entity_shaders_gles.h"
#include "impeller/entity/gles/framebuffer_blend_shaders_gles.h"
#include "impeller/entity/gles/modern_shaders_gles.h"
#include "impeller/renderer/backend/gles/context_gles.h"
#include "impeller/renderer/backend/gles/proc_table_gles.h"
#include "impeller/renderer/backend/gles/reactor_gles.h"
#include "impeller/renderer/backend/gles/surface_gles.h"
#include "impeller/renderer/renderer.h"

using namespace impeller;

class ReactorWorker final : public ReactorGLES::Worker {
 public:
  bool CanReactorReactOnCurrentThreadNow(const ReactorGLES&) const override {
    return true;
  }
};

static std::vector<std::shared_ptr<fml::Mapping>> ShaderMappings() {
  return {
      std::make_shared<fml::NonOwnedMapping>(
          impeller_entity_shaders_gles_data, impeller_entity_shaders_gles_length),
      std::make_shared<fml::NonOwnedMapping>(
          impeller_modern_shaders_gles_data, impeller_modern_shaders_gles_length),
      std::make_shared<fml::NonOwnedMapping>(
          impeller_framebuffer_blend_shaders_gles_data,
          impeller_framebuffer_blend_shaders_gles_length),
  };
}

static std::shared_ptr<Image> MakeTestImage(const std::shared_ptr<Context>& ctx) {
  TextureDescriptor desc;
  desc.format = PixelFormat::kR8G8B8A8UNormInt;
  desc.size = ISize::MakeWH(256, 256);
  desc.storage_mode = StorageMode::kHostVisible;
  auto tex = ctx->GetResourceAllocator()->CreateTexture(desc);
  if (!tex) return nullptr;
  std::vector<uint8_t> px(256 * 256 * 4);
  for (int y = 0; y < 256; y++)
    for (int x = 0; x < 256; x++) {
      auto* p = &px[(y * 256 + x) * 4];
      bool sq1 = x < 128 && y < 128, sq2 = x >= 120 && y >= 120;
      p[0] = sq1 ? 30 : (sq2 ? 255 : 60);
      p[1] = sq1 ? 120 : (sq2 ? 255 : 160);
      p[2] = sq1 ? 220 : (sq2 ? 40 : 200);
      p[3] = 255;
    }
  tex->SetContents(px.data(), px.size());
  return std::make_shared<Image>(tex);
}

static void DrawScene(Canvas& canvas, int scene, float w, float h,
                      const std::shared_ptr<Image>& img) {
  Paint white;
  white.color = Color::White();
  canvas.DrawPaint(white);
  switch (scene) {
    case 1:
      for (int i = 0; i < 200; i++) {
        Paint p;
        p.color = Color(i * 37 % 255 / 255.f, i * 91 % 255 / 255.f,
                        i * 57 % 255 / 255.f, 0.55f);
        float x = fmodf(i * 13.f, w - 60.f), y = fmodf(i * 29.f, h - 40.f);
        if (i % 3 == 0) canvas.DrawRect(Rect::MakeLTRB(x, y, x + 60, y + 40), p);
        else if (i % 3 == 1) canvas.DrawCircle(Point::MakeXY(x + 25, y + 25), 25, p);
        else canvas.DrawRRect(Rect::MakeLTRB(x, y, x + 70, y + 30), Size::MakeWH(8, 8), p);
      }
      break;
    case 3:
      for (int i = 0; i < 8; i++) {
        Paint p;
        p.color = Color(i * 30 % 255 / 255.f, (80 + i * 15) / 255.f, 220 / 255.f, 0.85f);
        p.mask_blur_descriptor = Paint::MaskBlurDescriptor{
            FilterContents::BlurStyle::kNormal, Sigma(14)};
        canvas.DrawOval(Rect::MakeLTRB(40 + i * 90.f, 120 + i * 45.f,
                                       180 + i * 90.f, 260 + i * 45.f), p);
      }
      break;
    case 4:
      for (int i = 0; i < 50; i++) {
        canvas.DrawImageRect(
            img, Rect::MakeXYWH(0, 0, 256, 256),
            Rect::MakeLTRB(fmodf(i * 67.f, w - 120.f), fmodf(i * 43.f, h - 120.f),
                           fmodf(i * 67.f, w - 120.f) + 120.f,
                           fmodf(i * 43.f, h - 120.f) + 120.f),
            Paint(), SamplerDescriptor{});
      }
      break;
    case 6: {
      Paint p;
      p.color = Color(20 / 255.f, 40 / 255.f, 160 / 255.f, 0.8f);
      p.style = Paint::Style::kStroke;
      p.stroke_width = 2;
      for (int i = 0; i < 100; i++) {
        PathBuilder pb;
        pb.MoveTo(Point::MakeXY(fmodf(i * 7.f, w), h - 60.f));
        pb.CubicCurveTo(Point::MakeXY(60 + i * 5, 80 + i * 2),
                        Point::MakeXY(320 - i, 40 + i * 4),
                        Point::MakeXY(700, fmodf(300 + i * 6.f, h - 20.f)));
        canvas.DrawPath(pb.TakePath(), p);
      }
      break;
    }
    case 8:
      for (int i = 0; i < 10; i++) {
        canvas.Save();
        canvas.ClipRect(Rect::MakeLTRB(60 + i * 40.f, 60 + i * 30.f,
                                       460 + i * 20.f, 320 + i * 18.f));
        canvas.Translate(Vector3(20 + i * 10, 10 + i * 8, 0));
        canvas.Rotate(Radians((3 + i) * 3.14159f / 180.f));
        Paint p;
        p.color = Color((40 + i * 20) / 255.f, (180 - i * 10) / 255.f, 120 / 255.f, 0.43f);
        canvas.DrawRect(Rect::MakeLTRB(0, 0, 500, 320), p);
        canvas.Restore();
      }
      for (int i = 0; i < 20; i++) {
        Paint p;
        p.color = Color(230 / 255.f, 128 / 255.f, 51 / 255.f, 0.6f);
        canvas.DrawOval(Rect::MakeLTRB(i * 30.f, i * 22.f, i * 30.f + 80, i * 22.f + 80), p);
      }
      break;
  }
}

static const char* GetGLRendererString() {
  static char buf[128] = "?";
  using Fn = const GLubyte* (*)(GLenum);
  auto fn = reinterpret_cast<Fn>(SDL_GL_GetProcAddress("glGetString"));
  if (fn) {
    const GLubyte* s = fn(GL_RENDERER);
    if (s) snprintf(buf, sizeof(buf), "%s", (const char*)s);
  }
  return buf;
}

int main(int argc, char** argv) {
  int scene = argc > 1 ? atoi(argv[1]) : 1;
  int frames_max = argc > 2 ? atoi(argv[2]) : 120;

  SDL_SetAppMetadata("i0-impeller", "0.1", "com.vehicoule.i0");
  if (!SDL_Init(SDL_INIT_VIDEO)) return 2;
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
  SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
  SDL_Window* win = SDL_CreateWindow("i0-impeller", 800, 600, SDL_WINDOW_OPENGL);
  SDL_GLContext glctx = SDL_GL_CreateContext(win);
  SDL_GL_MakeCurrent(win, glctx);
  SDL_GL_SetSwapInterval(1);

  auto gl = std::make_unique<ProcTableGLES>(
      [](const char* name) -> void* {
        return reinterpret_cast<void*>(SDL_GL_GetProcAddress(name));
      });
  if (!gl->IsValid()) { fprintf(stderr, "proc table invalid\n"); return 3; }

  auto context = ContextGLES::Create(std::move(gl), ShaderMappings(), false);
  if (!context) { fprintf(stderr, "context gles null\n"); return 4; }
  auto worker = std::make_shared<ReactorWorker>();
  context->AddReactorWorker(worker);

  auto renderer = std::make_shared<Renderer>(context);
  AiksContext aiks(context, /*typographer=*/nullptr);
  if (!aiks.IsValid()) { fprintf(stderr, "aiks invalid\n"); return 5; }

  auto img = MakeTestImage(context);

  std::vector<double> times;
  double total_ms = 0;
  int frames = 0;
  auto t_start = std::chrono::steady_clock::now();
  for (int f = 0; f < frames_max; f++) {
    SDL_Event ev;
    while (SDL_PollEvent(&ev)) if (ev.type == SDL_EVENT_QUIT) break;
    auto t0 = std::chrono::steady_clock::now();
    Canvas canvas(Rect::MakeLTRB(0, 0, 800, 600));
    DrawScene(canvas, scene, 800, 600, img);
    auto picture = canvas.EndRecordingAsPicture();
    auto surface = SurfaceGLES::WrapFBO(context, []() { return true; }, 0u,
                                        PixelFormat::kR8G8B8A8UNormInt,
                                        ISize::MakeWH(800, 600));
    bool ok = renderer->Render(std::move(surface),
                               [&](RenderTarget& rt) {
                                 return aiks.Render(picture, rt, true);
                               });
    SDL_GL_SwapWindow(win);
    auto t1 = std::chrono::steady_clock::now();
    if (!ok) { fprintf(stderr, "render fail frame %d\n", f); break; }
    times.push_back(std::chrono::duration<double, std::milli>(t1 - t0).count());
    frames++;
  }
  auto t_end = std::chrono::steady_clock::now();
  total_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();

  double sum = 0;
  for (double t : times) sum += t;
  double avg = times.empty() ? 0 : sum / times.size();
  printf("{\"tool\":\"i0-impeller-gles\",\"driver\":\"impeller-gles(%s)\","
         "\"scene\":\"s%d\",\"frames\":%d,\"total_ms\":%.1f,"
         "\"avg_frame_ms\":%.3f,\"first_frame_ms\":%.3f}\n",
         GetGLRendererString(),
         scene, frames, total_ms, avg, times.empty() ? 0 : times[0]);

  SDL_GL_DestroyContext(glctx);
  SDL_DestroyWindow(win);
  SDL_Quit();
  return 0;
}
