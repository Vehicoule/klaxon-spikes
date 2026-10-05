// K2-prep — SDLSurface + AccessibilityNodeProvider + exploration tactile.
// SDL dessine dans cette SurfaceView ; l'arbre virtuel simulé (zig) est
// exposé à TalkBack via KxA11y. Les mouvements de survol (exploration
// tactile TalkBack) déclenchent des events hover enter/exit virtuels.
package org.libsdl.app;

import android.content.Context;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewParent;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeProvider;

public class KxSurface extends SDLSurface {

    private static final String TAG = "KX-A11Y";
    private final KxA11yProvider provider;
    private int lastHoverVirtual = -1;

    public KxSurface(Context context) {
        super(context);
        provider = new KxA11yProvider(this);
        // La vue doit déclarer être "important for accessibility" pour que
        // TalkBack l'interroge.
        setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_YES);
    }

    @Override
    public AccessibilityNodeProvider getAccessibilityNodeProvider() {
        Log.i(TAG, "getAccessibilityNodeProvider -> " + (provider != null));
        return provider;
    }

    @Override
    public boolean dispatchHoverEvent(MotionEvent event) {
        int id = KxA11yProvider.hitTest(event.getX(), event.getY());
        if (id != lastHoverVirtual) {
            if (lastHoverVirtual >= 0) {
                sendVirtualHover(AccessibilityEvent.TYPE_VIEW_HOVER_EXIT,
                                 lastHoverVirtual);
            }
            if (id >= 0) {
                sendVirtualHover(AccessibilityEvent.TYPE_VIEW_HOVER_ENTER, id);
            }
            lastHoverVirtual = id;
        }
        return super.dispatchHoverEvent(event);
    }

    private void sendVirtualHover(int type, int virtualId) {
        AccessibilityManager am = (AccessibilityManager) getContext()
            .getSystemService(Context.ACCESSIBILITY_SERVICE);
        if (am == null || !am.isEnabled()) return;
        AccessibilityEvent ev = AccessibilityEvent.obtain(type);
        ev.setSource(this, virtualId);
        ev.setClassName(getClass().getName());
        ev.setPackageName(getContext().getPackageName());
        ViewParent p = getParent();
        if (p != null) {
            Log.i(TAG, "sendVirtualHover type=" + type + " id=" + virtualId);
            p.requestSendAccessibilityEvent(this, ev);
        }
    }
}
