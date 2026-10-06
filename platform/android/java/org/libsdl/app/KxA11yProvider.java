// K3 — pont TalkBack canonique : AccessibilityNodeProvider tenu par la
// SurfaceView SDL, alimenté en PUSH par le shim natif (kx_a11y_sync_*).
// Store : nodeId (int, assigné côté shim à partir de l'ident Node*) → Node.
// Strings copiées à onSyncItem. Événements émis sur mutations/focus delta.
package org.libsdl.app;

import android.content.Context;
import android.graphics.Rect;
import android.os.Bundle;
import android.util.Log;
import android.util.SparseArray;
import android.view.View;
import android.view.ViewParent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;

public class KxA11yProvider extends AccessibilityNodeProvider {

    private static final String TAG = "KX-A11Y";

    // ---- store poussé par le shim (thread SDL, sous lock) ----
    static final class Node {
        int role;          // 0 generic,1 button,2 checkbox,3 slider,
                           // 4 textfield,5 list,6 listitem,7 heading,8 group
        String label = "", hint = "";
        float x, y, w, h;  // coords vue (= écran : surface plein écran)
        int flags;         // 1 DISABLED|2 FOCUSABLE|4 FOCUSED|8 SELECTED
        int parentId;      // 0 = racine (host view)
    }

    private static final Object LOCK = new Object();
    private static final SparseArray<Node> cur = new SparseArray<>(); // live
    private static final SparseArray<Node> next = new SparseArray<>(); // building
    private static View sHost;          // surface porteuse (pour events + loc écran)
    private static int lastFocusedId = -1;   // flags&4 observé au dernier sync
    private static int a11yFocusId = -1;     // focus TalkBack (ACCESSIBILITY_FOCUS)
    private static int syncCount = 0;

    private final View host;

    public KxA11yProvider(View host) {
        this.host = host;
        sHost = host;
    }

    // ---- natives : shim → Java ----
    private static float sScale = 1f;   // UI-units → px écran (dp sur Android)

    public static synchronized void onSyncBegin(float scale) {
        sScale = scale > 0f ? scale : 1f;
        next.clear();
    }

    public static synchronized void onSyncItem(int id, int role, String label,
            String hint, float x, float y, float w, float h, int flags,
            int parentId) {
        Node n = new Node();
        n.role = role;
        n.label = label != null ? label : "";
        n.hint = hint != null ? hint : "";
        // bounds UI (dp) → coords écran px (TalkBack exige des pixels).
        n.x = x * sScale; n.y = y * sScale; n.w = w * sScale; n.h = h * sScale;
        n.flags = flags;
        n.parentId = parentId;
        next.put(id, n);
    }

    public static synchronized int onSyncEnd() {
        syncCount++;
        int mutated = 0;
        if (cur.size() != next.size()) {
            mutated = 1;
        } else {
            for (int i = 0; i < next.size(); i++) {
                int id = next.keyAt(i);
                Node a = cur.get(id), b = next.valueAt(i);
                if (a == null || !sameNode(a, b)) { mutated = 1; break; }
            }
        }
        cur.clear();
        for (int i = 0; i < next.size(); i++) {
            cur.put(next.keyAt(i), next.valueAt(i));
        }
        int fid = -1;
        for (int i = 0; i < cur.size(); i++) {
            Node n = cur.valueAt(i);
            if ((n.flags & 4) != 0) { fid = cur.keyAt(i); break; }
        }
        final int fmut = mutated, ffid = fid;
        final boolean focusDelta = ffid != lastFocusedId;
        lastFocusedId = ffid;
        if (sHost != null) {
            sHost.post(() -> {
                if (fmut != 0) sendEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED, HOST_VIEW_ID);
                if (focusDelta && ffid >= 0) {
                    sendEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED, ffid);
                    Node n;
                    synchronized (KxA11yProvider.class) { n = cur.get(ffid); }
                    if (n != null && n.role == 6) {
                        sendEvent(AccessibilityEvent.TYPE_VIEW_SELECTED, ffid);
                    }
                }
            });
        }
        if (fmut != 0 || focusDelta) {
            Log.i(TAG, "onSyncEnd mutated=" + fmut + " nodes=" + cur.size()
                    + " focusId=" + ffid + " syncs=" + syncCount);
        }
        return fmut;
    }

    private static boolean sameNode(Node a, Node b) {
        return a.role == b.role && a.flags == b.flags && a.parentId == b.parentId
            && a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h
            && a.label.equals(b.label) && a.hint.equals(b.hint);
    }

    private static void sendEvent(int type, int vid) {
        if (sHost == null) return;
        AccessibilityManager am = (AccessibilityManager) sHost.getContext()
            .getSystemService(Context.ACCESSIBILITY_SERVICE);
        if (am == null || !am.isEnabled()) return;
        AccessibilityEvent ev = AccessibilityEvent.obtain(type);
        ev.setSource(sHost, vid);
        ev.setClassName(sHost.getClass().getName());
        ev.setPackageName(sHost.getContext().getPackageName());
        ViewParent p = sHost.getParent();
        if (p != null) p.requestSendAccessibilityEvent(sHost, ev);
        Log.i(TAG, "event type=" + type + " vid=" + vid);
    }

    // ---- provider ----
    private static String classOf(int role) {
        switch (role) {
            case 1: return "android.widget.Button";
            case 2: return "android.widget.CheckBox";
            case 3: return "android.widget.SeekBar";
            case 4: return "android.widget.EditText";
            case 5: return "android.widget.ListView";
            case 8: return "android.view.ViewGroup";
            case 6:
            case 7:
            default: return "android.widget.TextView";
        }
    }

    private static boolean clickable(int role, int flags) {
        return (flags & 2) != 0 || role == 1 || role == 2 || role == 3
            || role == 4 || role == 6;
    }

    @Override
    public AccessibilityNodeInfo createAccessibilityNodeInfo(int virtualViewId) {
        if (virtualViewId == HOST_VIEW_ID) {
            AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(host);
            host.onInitializeAccessibilityNodeInfo(info);
            synchronized (LOCK) {
                for (int i = 0; i < cur.size(); i++) {
                    if (cur.valueAt(i).parentId == 0) {
                        info.addChild(host, cur.keyAt(i));
                    }
                }
            }
            return info;
        }
        Node n;
        synchronized (LOCK) { n = cur.get(virtualViewId); }
        if (n == null) return null;

        AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(host, virtualViewId);
        info.setSource(host, virtualViewId);
        info.setPackageName(host.getContext().getPackageName());
        info.setClassName(classOf(n.role));
        info.setText(n.label);
        info.setContentDescription(n.hint.isEmpty() ? n.label
                : n.label + " " + n.hint);
        info.setEnabled((n.flags & 1) == 0);
        info.setVisibleToUser(true);
        info.setFocusable((n.flags & 2) != 0);
        info.setFocused((n.flags & 4) != 0);
        info.setSelected((n.flags & 8) != 0);
        info.setClickable(clickable(n.role, n.flags));
        if (n.role == 2 || n.role == 3) { // checkbox | slider
            info.setCheckable(true);
            info.setChecked((n.flags & 8) != 0);
        }
        if (n.role == 4) info.setEditable(true);
        if (n.role == 7) info.setHeading(true);
        if ((n.flags & 2) != 0) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_FOCUS);
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_ACCESSIBILITY_FOCUS);
        }
        if (clickable(n.role, n.flags)) {
            info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_CLICK);
        }

        Rect bounds = new Rect((int) n.x, (int) n.y,
                               (int) (n.x + n.w), (int) (n.y + n.h));
        info.setBoundsInParent(new Rect(bounds));
        int[] loc = new int[2];
        host.getLocationOnScreen(loc);
        bounds.offset(loc[0], loc[1]);
        info.setBoundsInScreen(bounds);

        if (n.parentId > 0) {
            info.setParent(host, n.parentId);
        } else {
            info.setParent(host);
        }
        synchronized (LOCK) {
            for (int i = 0; i < cur.size(); i++) {
                if (cur.valueAt(i).parentId == virtualViewId) {
                    info.addChild(host, cur.keyAt(i));
                }
            }
        }
        return info;
    }

    @Override
    public AccessibilityNodeInfo findFocus(int focus) {
        Log.i(TAG, "findFocus focus=" + focus);
        int id = -1;
        if (focus == AccessibilityNodeInfo.FOCUS_ACCESSIBILITY) {
            id = a11yFocusId;
            if (id < 0) {
                synchronized (LOCK) {
                    for (int i = 0; i < cur.size(); i++) {
                        if ((cur.valueAt(i).flags & 4) != 0) { id = cur.keyAt(i); break; }
                    }
                }
            }
        } else if (focus == AccessibilityNodeInfo.FOCUS_INPUT) {
            synchronized (LOCK) {
                for (int i = 0; i < cur.size(); i++) {
                    if ((cur.valueAt(i).flags & 4) != 0) { id = cur.keyAt(i); break; }
                }
            }
        }
        return id >= 0 ? createAccessibilityNodeInfo(id) : null;
    }

    @Override
    public boolean performAction(int virtualViewId, int action, Bundle arguments) {
        Log.i(TAG, "performAction id=" + virtualViewId + " action=" + action);
        if (virtualViewId == HOST_VIEW_ID) {
            return host.performAccessibilityAction(action, arguments);
        }
        if (action == AccessibilityNodeInfo.ACTION_CLICK) {
            nativePerformAction(virtualViewId, 0); // 0 = press (contrat)
            return true;
        }
        if (action == AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS) {
            a11yFocusId = virtualViewId;
            sendEvent(AccessibilityEvent.TYPE_VIEW_FOCUSED, virtualViewId);
            Node n;
            synchronized (LOCK) { n = cur.get(virtualViewId); }
            if (n != null && n.role == 6) {
                sendEvent(AccessibilityEvent.TYPE_VIEW_SELECTED, virtualViewId);
            }
            return true;
        }
        if (action == AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS) {
            if (a11yFocusId == virtualViewId) a11yFocusId = -1;
            sendEvent(AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED, virtualViewId);
            return true;
        }
        if (action == AccessibilityNodeInfo.ACTION_FOCUS && virtualViewId >= 0) {
            nativePerformAction(virtualViewId, 1); // 1 = focus (ext locale)
            return true;
        }
        return false;
    }

    /** pont debug (K3) : exécute performAction du provider depuis un intent
        -e kx_a11y_action <id> — même chemin qu'ACTION_CLICK TalkBack, seul
        l'appelant est simulé (gestes TalkBack non injectables sur émulateur). */
    public static void debugPerform(final int id, final int action) {
        if (sHost == null) return;
        sHost.postDelayed(() -> {
            KxA11yProvider p = (KxA11yProvider) sHost.getAccessibilityNodeProvider();
            boolean r = p.performAction(id, action, null);
            Log.i(TAG, "debugPerform id=" + id + " action=" + action + " -> " + r);
        }, 800);
    }

    /** hit test pour l'exploration tactile (KxSurface.dispatchHoverEvent). */
    public static int hitTest(float x, float y) {
        synchronized (LOCK) {
            for (int i = cur.size() - 1; i >= 0; i--) {
                Node n = cur.valueAt(i);
                if (x >= n.x && x < n.x + n.w && y >= n.y && y < n.y + n.h) {
                    return cur.keyAt(i);
                }
            }
        }
        return -1;
    }

    // ---- natives : Java → shim ----
    private static native void nativePerformAction(int nodeId, int action);
}
