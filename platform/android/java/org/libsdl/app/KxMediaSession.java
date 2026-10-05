package org.libsdl.app;

// MediaSession ADR-0005 : pilotage OS (lockscreen/notif/media boutons).
// Callbacks session → nativeMediaCommand → zig (marshal thread SDL, même
// forme que KxA11yProvider.nativePerformAction). Publish state/meta via JNI
// depuis le thread SDL.

import android.content.Context;
import android.content.Intent;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.util.Log;
import android.view.KeyEvent;

public final class KxMediaSession {
    private static final String TAG = "KX-MEDIA";
    private static MediaSession sSession;

    // actions zig (ordre figé) : 0 play,1 pause,2 next,3 prev,4 seek(arg µs),5 stop
    public static native void nativeMediaCommand(int action, long arg);

    private static long actions() {
        return PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
            | PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_SKIP_TO_NEXT
            | PlaybackState.ACTION_SKIP_TO_PREVIOUS | PlaybackState.ACTION_SEEK_TO
            | PlaybackState.ACTION_STOP;
    }

    @SuppressWarnings("deprecation")
    public static synchronized void install(Context ctx) {
        if (sSession != null) return;
        sSession = new MediaSession(ctx, "klaxon");
        sSession.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        sSession.setCallback(new MediaSession.Callback() {
            @Override public void onPlay() {
                Log.i(TAG, "cb onPlay"); nativeMediaCommand(0, 0);
            }
            @Override public void onPause() {
                Log.i(TAG, "cb onPause"); nativeMediaCommand(1, 0);
            }
            @Override public void onSkipToNext() {
                Log.i(TAG, "cb onSkipToNext"); nativeMediaCommand(2, 0);
            }
            @Override public void onSkipToPrevious() {
                Log.i(TAG, "cb onSkipToPrevious"); nativeMediaCommand(3, 0);
            }
            @Override public void onSeekTo(long posMs) {
                Log.i(TAG, "cb onSeekTo " + posMs);
                nativeMediaCommand(4, posMs * 1000); // ms → µs côté ABI zig
            }
            @Override public void onStop() {
                Log.i(TAG, "cb onStop"); nativeMediaCommand(5, 0);
            }
            @Override public void onPlayFromMediaId(String id, android.os.Bundle b) {
                Log.i(TAG, "cb onPlayFromMediaId " + id); nativeMediaCommand(0, 0);
            }
            @Override public boolean onMediaButtonEvent(Intent e) {
                KeyEvent k = e.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
                Log.i(TAG, "mediaButton key=" + (k != null ? k.getKeyCode() : -1)
                    + " action=" + (k != null ? k.getAction() : -1));
                return super.onMediaButtonEvent(e);
            }
        });
        sSession.setPlaybackState(new PlaybackState.Builder()
            .setActions(actions())
            .setState(PlaybackState.STATE_STOPPED, 0, 1f)
            .build());
        sSession.setActive(true);
        Log.i(TAG, "session installed + active");
    }

    public static synchronized void release() {
        if (sSession == null) return;
        sSession.setActive(false);
        sSession.release();
        sSession = null;
        Log.i(TAG, "session released");
    }

    // ---- appelés via JNI depuis le zig (thread SDL) ----
    // state : 0 stopped, 1 playing, 2 paused (enum côté zig)
    public static synchronized void publishState(int state, long posUs,
            double speed, long durUs) {
        if (sSession == null) return;
        int st = state == 1 ? PlaybackState.STATE_PLAYING
             : state == 2 ? PlaybackState.STATE_PAUSED
                          : PlaybackState.STATE_STOPPED;
        sSession.setPlaybackState(new PlaybackState.Builder()
            .setActions(actions())
            .setState(st, posUs / 1000, (float) speed)
            .build());
        Log.i(TAG, "publishState st=" + st + " posMs=" + (posUs / 1000));
    }

    public static synchronized void publishMeta(String title, String artist,
            long durMs) {
        if (sSession == null) return;
        sSession.setMetadata(new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, durMs)
            .build());
        Log.i(TAG, "publishMeta \"" + title + "\" " + durMs + "ms");
    }

    // Seek via le vrai TransportControls de la session (test/debug).
    public static void debugSeek(long ms) {
        MediaSession s = sSession;
        if (s != null) s.getController().getTransportControls().seekTo(ms);
    }

    // action : 0 play,1 pause,2 next,3 prev,4 seek(arg=ms),5 stop — le même
    // chemin que les contrôles lockscreen/notif (MediaController→callback).
    public static void debugTransport(int action, long arg) {
        MediaSession s = sSession;
        if (s == null) return;
        android.media.session.MediaController.TransportControls tc =
            s.getController().getTransportControls();
        switch (action) {
            case 0: tc.play(); break;
            case 1: tc.pause(); break;
            case 2: tc.skipToNext(); break;
            case 3: tc.skipToPrevious(); break;
            case 4: tc.seekTo(arg); break;
            case 5: tc.stop(); break;
        }
        Log.i(TAG, "debugTransport a=" + action + " arg=" + arg);
    }
}
