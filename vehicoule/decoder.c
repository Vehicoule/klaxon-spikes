// decoder.c — décodeur fichier→PCM f32 interleaved pour V0.
// dr_libs single-headers (public domain / MIT-0) : mp3, flac, wav.
// Décodage entier à l'ouverture : seek = déplacement de curseur, zéro
// re-decode. ~10 Mo/minute stéréo 48k — acceptable pour V0 (noté).
#define DR_MP3_IMPLEMENTATION
#define DR_FLAC_IMPLEMENTATION
#define DR_WAV_IMPLEMENTATION
#define STB_VORBIS_HEADER_ONLY
#include "vendor/dr_mp3.h"
#include "vendor/dr_flac.h"
#include "vendor/dr_wav.h"
#include "vendor/stb_vorbis.c"
#include <opusfile.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <sys/wait.h>
#include <fcntl.h>

// iOS : pas de fork/exec ni ffmpeg → fallback externe désactivé (refus
// honnête m4a/aac/wma — même sémantique « decode failed » côté moteur).
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#define KXD_NO_FFMPEG 1
#endif
#endif
// Android : SELinux interdit execve hors sandbox app (API>=29) — refus
// honnête identique.
#if defined(__ANDROID__) && !defined(KXD_NO_FFMPEG)
#define KXD_NO_FFMPEG 1
#endif

typedef enum { KXD_MP3, KXD_FLAC, KXD_WAV, KXD_VORBIS, KXD_OPUS, KXD_FFMPEG } kxd_kind;

typedef struct {
    kxd_kind kind;
    drmp3* mp3;
    drflac* flac;
    drwav* wav;
    stb_vorbis* vorbis;
    OggOpusFile* opus;
    // buffer décodé entier
    float* pcm;            // interleaved, frames*channels
    drwav_uint64 frames;   // frames totales
    drwav_uint64 cursor;   // frame courante
    unsigned rate, channels;
} kxd;

static int has_ext(const char* path, const char* ext) {
    size_t lp = strlen(path), le = strlen(ext);
    return lp > le && strcasecmp(path + lp - le, ext) == 0;
}

void* kxdec_open(const char* path) {
    if (!path) return NULL;
    kxd* d = calloc(1, sizeof(kxd));
    if (!d) return NULL;
    if (has_ext(path, ".mp3")) {
        d->mp3 = malloc(sizeof(drmp3));
        if (!d->mp3 || !drmp3_init_file(d->mp3, path, NULL)) goto fail;
        d->kind = KXD_MP3;
        d->rate = d->mp3->sampleRate;
        d->channels = d->mp3->channels;
        drmp3_uint64 n = drmp3_get_pcm_frame_count(d->mp3);
        d->pcm = malloc((size_t)n * d->channels * sizeof(float));
        if (!d->pcm) goto fail;
        d->frames = drmp3_read_pcm_frames_f32(d->mp3, n, d->pcm);
    } else if (has_ext(path, ".flac")) {
        d->flac = drflac_open_file(path, NULL);
        if (!d->flac) goto fail;
        d->kind = KXD_FLAC;
        d->rate = d->flac->sampleRate;
        d->channels = d->flac->channels;
        drwav_uint64 n = d->flac->totalPCMFrameCount;
        d->pcm = malloc((size_t)n * d->channels * sizeof(float));
        if (!d->pcm) goto fail;
        d->frames = drflac_read_pcm_frames_f32(d->flac, n, d->pcm);
    } else if (has_ext(path, ".ogg") || has_ext(path, ".oga")) {
        int err = 0;
        d->vorbis = stb_vorbis_open_filename(path, &err, NULL);
        if (!d->vorbis) goto fail;
        d->kind = KXD_VORBIS;
        stb_vorbis_info vi = stb_vorbis_get_info(d->vorbis);
        d->rate = vi.sample_rate;
        d->channels = vi.channels;
        drwav_uint64 n = stb_vorbis_stream_length_in_samples(d->vorbis);
        d->pcm = malloc((size_t)n * d->channels * sizeof(float));
        if (!d->pcm) goto fail;
        d->frames = stb_vorbis_get_samples_float_interleaved(d->vorbis,
            d->channels, d->pcm, (int)(n * d->channels));
    } else if (has_ext(path, ".opus")) {
        int err = 0;
        d->opus = op_open_file(path, &err);
        if (!d->opus) goto fail;
        d->kind = KXD_OPUS;
        // sortie toujours stéréo f32 @48k (rate interne opus)
        d->rate = 48000;
        d->channels = 2;
        ogg_int64_t n = op_pcm_total(d->opus, -1);
        d->pcm = malloc((size_t)n * 2 * sizeof(float));
        if (!d->pcm) goto fail;
        drwav_uint64 got = 0;
        while (got < (drwav_uint64)n) {
            int r = op_read_float_stereo(d->opus,
                d->pcm + got * 2, (int)((n - got) * 2));
            if (r <= 0) break;
            got += (drwav_uint64)r;
        }
        d->frames = got;
    } else if (has_ext(path, ".wav")) {
        d->wav = malloc(sizeof(drwav));
        if (!d->wav || !drwav_init_file(d->wav, path, NULL)) goto fail;
        d->kind = KXD_WAV;
        d->rate = d->wav->sampleRate;
        d->channels = d->wav->channels;
        drwav_uint64 n = d->wav->totalPCMFrameCount;
        d->pcm = malloc((size_t)n * d->channels * sizeof(float));
        if (!d->pcm) goto fail;
        d->frames = drwav_read_pcm_frames_f32(d->wav, n, d->pcm);
    } else {
        // décodeur OS (ADR-0005) : ffmpeg externe pour aac/m4a/wma et le
        // reste — fork/exec sans shell, sortie f32 stéréo @48k sur pipe.
#if defined(KXD_NO_FFMPEG)
        goto fail;
#else
        d->kind = KXD_FFMPEG;
        d->rate = 48000;
        d->channels = 2;
        int pipefd[2];
        if (pipe(pipefd) != 0) goto fail;
        pid_t pid = fork();
        if (pid == 0) {
            dup2(pipefd[1], 1);
            close(pipefd[0]); close(pipefd[1]);
            int devnull = open("/dev/null", O_WRONLY);
            if (devnull >= 0) { dup2(devnull, 2); close(devnull); }
            execlp("ffmpeg", "ffmpeg", "-v", "error", "-i", path,
                   "-f", "f32le", "-ac", "2", "-ar", "48000", "pipe:1", NULL);
            _exit(127);
        }
        close(pipefd[1]);
        if (pid < 0) { close(pipefd[0]); goto fail; }
        size_t cap = 1 << 22, len = 0;
        d->pcm = malloc(cap);
        if (!d->pcm) { close(pipefd[0]); waitpid(pid, NULL, 0); goto fail; }
        for (;;) {
            if (len == cap) {
                cap *= 2;
                float* np = realloc(d->pcm, cap);
                if (!np) break;
                d->pcm = np;
            }
            ssize_t r = read(pipefd[0], (char*)d->pcm + len, cap - len);
            if (r <= 0) break;
            len += (size_t)r;
        }
        close(pipefd[0]);
        int st = 0; waitpid(pid, &st, 0);
        if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) goto fail; // ffmpeg absent/erreur → refus honnête
        d->frames = len / (2 * sizeof(float));
#endif
    }
    if (!d->frames || !d->pcm) goto fail;
    return d;
fail:
    free(d->pcm); free(d->mp3); if (d->flac) drflac_close(d->flac);
    if (d->vorbis) stb_vorbis_close(d->vorbis);
    if (d->opus) op_free(d->opus);
    free(d->wav); free(d);
    return NULL;
}

unsigned kxdec_rate(void* h) { return ((kxd*)h)->rate; }
unsigned kxdec_channels(void* h) { return ((kxd*)h)->channels; }
drwav_uint64 kxdec_frames(void* h) { return ((kxd*)h)->frames; }
drwav_uint64 kxdec_cursor(void* h) { return ((kxd*)h)->cursor; }

drwav_uint64 kxdec_read(void* h, float* dst, drwav_uint64 want) {
    kxd* d = (kxd*)h;
    drwav_uint64 avail = d->frames - d->cursor;
    drwav_uint64 n = want < avail ? want : avail;
    memcpy(dst, d->pcm + d->cursor * d->channels,
           (size_t)n * d->channels * sizeof(float));
    d->cursor += n;
    return n;
}

void kxdec_seek(void* h, drwav_uint64 frame) {
    kxd* d = (kxd*)h;
    d->cursor = frame > d->frames ? d->frames : frame;
}

void kxdec_close(void* h) {
    if (!h) return;
    kxd* d = (kxd*)h;
    if (d->mp3) { drmp3_uninit(d->mp3); free(d->mp3); }
    if (d->flac) drflac_close(d->flac);
    if (d->wav) { drwav_uninit(d->wav); free(d->wav); }
    if (d->vorbis) stb_vorbis_close(d->vorbis);
    if (d->opus) op_free(d->opus);
    free(d->pcm); free(d);
}
