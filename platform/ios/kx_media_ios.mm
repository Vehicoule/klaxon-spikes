// kx_media_ios.mm — MediaSession iOS (ADR-0005) : miroir du glue Android
// kx_gallery_glue.cpp, sur MPNowPlayingInfoCenter + MPRemoteCommandCenter.
//
// actions figées : 0 play, 1 pause, 2 next, 3 prev, 4 seek(arg µs), 5 stop.
// Le cb s'exécute sur le main thread (handlers MPRemoteCommand) — côté zig
// il ne fait qu'enregistrer un pending drainé dans tick() (même protocole
// que les actions a11y — aucun travail lourd ici).
//
// publish_state / publish_meta sont appelés depuis le thread SDL (main
// thread dans notre modèle — UIApplicationMain→forward→tick). On force
// quand même dispatch au main queue : MPNowPlayingInfoCenter n'est pas
// thread-safe documenté.

#import <MediaPlayer/MediaPlayer.h>
#import <Foundation/Foundation.h>

static void (*g_media_cb)(void*, int, long long) = nullptr;
static void* g_media_ctx = nullptr;
static dispatch_once_t g_install_once;

// state zig → MPNowPlayingInfoCenter : 0 stopped,1 playing,2 paused.
// On garde le dictionnaire courant pour mettre à jour elapsed/rate sans
// écraser title/artist publiés par publish_meta.
static NSMutableDictionary* g_np_info = nil;
static long long g_last_dur_us = 0;
static int g_last_state = 0;
static long long g_last_pos_us = 0;
static double g_last_speed = 0.0;
static long long g_state_at_ns = 0; // uptime au dernier publish_state

static void emit(int action, long long arg) {
    if (g_media_cb) g_media_cb(g_media_ctx, action, arg);
}

// ---- debug/mesure (hors scope prod) -------------------------------------
// KX_MEDIA_DUMP : écrit nowPlayingInfo → $HOME/Documents/nowplaying.json à
// chaque publish — vérifiable depuis l'hôte via le conteneur de l'app.
static void dumpNowPlaying(void) {
    static int dumped = 0;
    if (!dumped && !getenv("KX_MEDIA_DUMP")) { dumped = -1; return; }
    if (dumped < 0) return;
    dumped = 1;
    NSDictionary* info = [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo;
    NSString* home = NSHomeDirectory();
    NSString* path = [home stringByAppendingString:@"/Documents/nowplaying.json"];
    NSError* err = nil;
    NSData* js = info ? [NSJSONSerialization dataWithJSONObject:info
                         options:NSJSONWritingPrettyPrinted error:&err] : nil;
    if (js) [js writeToFile:path atomically:YES];
}

// KX_MEDIA_SELFTEST : à l'install des handlers, programme emit(2)=next à
// T+4s — simule exactement ce qu'un bouton lockscreen fait (même emit()).
// media_cmds≥1 dans les stats = chaîne bouton→cb→drain→action prouvée.
static void scheduleSelftest(void) {
    if (!getenv("KX_MEDIA_SELFTEST")) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4ll * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
      emit(2, 0);
    });
}

extern "C" void kx_media_set_action_handler(void (*cb)(void*, int, long long),
                                            void* ctx) {
    g_media_cb = cb;
    g_media_ctx = ctx;
    dispatch_once(&g_install_once, ^{
      MPRemoteCommandCenter* cc = [MPRemoteCommandCenter sharedCommandCenter];
      cc.playCommand.enabled = YES;
      [cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                          MPRemoteCommandEvent*) {
        emit(0, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.pauseCommand.enabled = YES;
      [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                           MPRemoteCommandEvent*) {
        emit(1, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.togglePlayPauseCommand.enabled = YES;
      [cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                   MPRemoteCommandEvent*) {
        // état courant connu → inverse (pas de bascule aveugle)
        emit(g_last_state == 1 ? 1 : 0, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.nextTrackCommand.enabled = YES;
      [cc.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                              MPRemoteCommandEvent*) {
        emit(2, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.previousTrackCommand.enabled = YES;
      [cc.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                                  MPRemoteCommandEvent*) {
        emit(3, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.stopCommand.enabled = YES;
      [cc.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(
                        MPRemoteCommandEvent*) {
        emit(5, 0);
        return MPRemoteCommandHandlerStatusSuccess;
      }];
      cc.changePlaybackPositionCommand.enabled = YES;
      [cc.changePlaybackPositionCommand
          addTargetWithHandler:^MPRemoteCommandHandlerStatus(
              MPRemoteCommandEvent* ev) {
            MPChangePlaybackPositionCommandEvent* pe =
                (MPChangePlaybackPositionCommandEvent*)ev;
            emit(4, (long long)(pe.positionTime * 1e6));
            return MPRemoteCommandHandlerStatusSuccess;
          }];
      scheduleSelftest();
    });
}

// position "live" : le player avance entre deux publish — extrapole depuis
// le dernier état connu (speed) pour que le lockscreen ne saute pas.
static double elapsedNow(void) {
    double pos = (double)g_last_pos_us / 1e6;
    if (g_last_state == 1 && g_state_at_ns > 0) {
        double dt = (double)([NSDate timeIntervalSinceReferenceDate] * 1e9 -
                             g_state_at_ns) / 1e9;
        pos += dt * g_last_speed;
    }
    return pos;
}

static void publishInfo(void) {
    if (!g_np_info) g_np_info = [[NSMutableDictionary alloc] init];
    g_np_info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsedNow());
    g_np_info[MPNowPlayingInfoPropertyPlaybackRate] =
        @(g_last_state == 1 ? g_last_speed : 0.0);
    if (g_last_dur_us > 0)
        g_np_info[MPMediaItemPropertyPlaybackDuration] =
            @((double)g_last_dur_us / 1e6);
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = g_np_info;
    if (@available(iOS 13.0, *)) {
        MPNowPlayingInfoCenter* c = [MPNowPlayingInfoCenter defaultCenter];
        switch (g_last_state) {
        case 1: c.playbackState = MPNowPlayingPlaybackStatePlaying; break;
        case 2: c.playbackState = MPNowPlayingPlaybackStatePaused; break;
        default: c.playbackState = MPNowPlayingPlaybackStateStopped; break;
        }
    }
    dumpNowPlaying();
}

extern "C" void kx_media_publish_state(int state, long long pos_us,
                                       double speed, long long dur_us) {
    g_last_state = state;
    g_last_pos_us = pos_us;
    g_last_speed = speed;
    g_last_dur_us = dur_us;
    g_state_at_ns = (long long)([NSDate timeIntervalSinceReferenceDate] * 1e9);
    if ([NSThread isMainThread])
        publishInfo();
    else
        dispatch_async(dispatch_get_main_queue(), ^{ publishInfo(); });
}

extern "C" void kx_media_publish_meta(const char* title, const char* artist,
                                      long long dur_ms) {
    NSString* t = title ? [[NSString alloc] initWithUTF8String:title] : @"";
    NSString* a = artist ? [[NSString alloc] initWithUTF8String:artist] : @"";
    if ([NSThread isMainThread]) {
        if (!g_np_info) g_np_info = [[NSMutableDictionary alloc] init];
        g_np_info[MPMediaItemPropertyTitle] = t;
        g_np_info[MPMediaItemPropertyArtist] = a;
        g_np_info[MPMediaItemPropertyPlaybackDuration] = @(dur_ms / 1000.0);
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = g_np_info;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!g_np_info) g_np_info = [[NSMutableDictionary alloc] init];
          g_np_info[MPMediaItemPropertyTitle] = t;
          g_np_info[MPMediaItemPropertyArtist] = a;
          g_np_info[MPMediaItemPropertyPlaybackDuration] = @(dur_ms / 1000.0);
          [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = g_np_info;
        });
    }
}
