// K2-prep — sondes WindowInsets, appelées via JNI depuis le code natif.
// Vérité terrain pour le bug #13166 : hauteur clavier (ime insets),
// barres système, hauteur réelle du decorView.
package org.libsdl.app;

import android.app.Activity;
import android.graphics.Insets;
import android.view.View;
import android.view.WindowInsets;

public class KxProbe {

    private static WindowInsets insets(Activity a) {
        if (a == null) return null;
        View v = a.getWindow().getDecorView();
        return (v != null) ? v.getRootWindowInsets() : null;
    }

    // Bord inférieur de l'inset IME en pixels (0 quand clavier caché).
    public static int imeBottom(Activity a) {
        WindowInsets i = insets(a);
        if (i == null) return -1;
        return i.getInsets(WindowInsets.Type.ime()).bottom;
    }

    public static int imeVisible(Activity a) {
        WindowInsets i = insets(a);
        if (i == null) return -1;
        return i.isVisible(WindowInsets.Type.ime()) ? 1 : 0;
    }

    public static int sysbarTop(Activity a) {
        WindowInsets i = insets(a);
        if (i == null) return -1;
        return i.getInsets(WindowInsets.Type.statusBars()).top;
    }

    public static int navBottom(Activity a) {
        WindowInsets i = insets(a);
        if (i == null) return -1;
        return i.getInsets(WindowInsets.Type.navigationBars()).bottom;
    }

    // Change windowSoftInputMode à la volée (pour les sondes #13166 :
    // 0x10=ADJUST_RESIZE, 0x20=ADJUST_NOTHING, 0x30=ADJUST_PAN).
    public static int setSoftInput(Activity a, int mode) {
        if (a == null) return -1;
        final Activity act = a;
        final int m = mode;
        act.runOnUiThread(() -> act.getWindow().setSoftInputMode(m));
        return 0;
    }

    // Hauteur totale du decorView (référence pour "bottom réel").
    public static int viewBottom(Activity a) {
        View v = (a != null) ? a.getWindow().getDecorView() : null;
        return (v != null) ? v.getHeight() : -1;
    }
}
