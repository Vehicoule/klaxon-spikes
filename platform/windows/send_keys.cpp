// send_keys.cpp — injection d'input RÉEL (SendInput) pour la vérif clavier.
//   send_keys.exe --fg                 → SetForegroundWindow(gallery)
//   send_keys.exe --click <x> <y>      → clic souris écran (client→écran = déjà écran)
//   send_keys.exe --type <utf8>        → KEYEVENTF_UNICODE par codepoint
//   send_keys.exe --key <vk>           → appui/relâche touche virtuelle (8=Backspace)
// Toutes les actions passent par SendInput — le vrai input path OS.

#include <windows.h>
#include <stdio.h>
#include <string>

static void sendVk(WORD vk, bool up) {
    INPUT in = {};
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    if (up) in.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &in, sizeof(INPUT));
}

int wmain(int argc, wchar_t** argv) {
    const wchar_t* cmd = argc > 1 ? argv[1] : L"";
    HWND hwnd = FindWindowW(nullptr, L"Klaxon Gallery");
    if (!hwnd) {
        printf("{\"tool\":\"kx-send-keys\",\"error\":\"window not found\"}\n");
        return 2;
    }
    if (!wcscmp(cmd, L"--fg")) {
        // SetForegroundWindow échoue souvent depuis un process tiers —
        // simulate Alt d'abord (astuce classique) puis tente.
        sendVk(VK_MENU, false); sendVk(VK_MENU, true);
        BOOL ok = SetForegroundWindow(hwnd);
        printf("{\"tool\":\"kx-send-keys\",\"action\":\"fg\",\"ok\":%d,\"fg\":\"%p\",\"want\":\"%p\"}\n",
               ok ? 1 : 0, (void*)GetForegroundWindow(), (void*)hwnd);
        return ok ? 0 : 3;
    }
    if (!wcscmp(cmd, L"--click") && argc > 3) {
        int x = _wtoi(argv[2]), y = _wtoi(argv[3]);
        SetCursorPos(x, y);
        INPUT in[2] = {};
        in[0].type = INPUT_MOUSE;
        in[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        in[1].type = INPUT_MOUSE;
        in[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        SendInput(2, in, sizeof(INPUT));
        printf("{\"tool\":\"kx-send-keys\",\"action\":\"click\",\"x\":%d,\"y\":%d,\"ok\":1}\n", x, y);
        return 0;
    }
    if (!wcscmp(cmd, L"--type") && argc > 2) {
        // UTF-16 natif (wmain) : un INPUT down+up par codepoint.
        const wchar_t* s = argv[2];
        int n = 0;
        for (const wchar_t* p = s; *p; ++p) {
            INPUT in[2] = {};
            in[0].type = INPUT_KEYBOARD;
            in[0].ki.wScan = *p;
            in[0].ki.dwFlags = KEYEVENTF_UNICODE;
            in[1] = in[0];
            in[1].ki.dwFlags |= KEYEVENTF_KEYUP;
            SendInput(2, in, sizeof(INPUT));
            n++;
            Sleep(15);
        }
        printf("{\"tool\":\"kx-send-keys\",\"action\":\"type\",\"chars\":%d,\"ok\":1}\n", n);
        return 0;
    }
    if (!wcscmp(cmd, L"--key") && argc > 2) {
        int vk = _wtoi(argv[2]);
        int reps = argc > 3 ? _wtoi(argv[3]) : 1;
        for (int i = 0; i < reps; ++i) {
            sendVk((WORD)vk, false);
            sendVk((WORD)vk, true);
            Sleep(15);
        }
        printf("{\"tool\":\"kx-send-keys\",\"action\":\"key\",\"vk\":%d,\"reps\":%d,\"ok\":1}\n", vk, reps);
        return 0;
    }
    printf("{\"tool\":\"kx-send-keys\",\"error\":\"usage\"}\n");
    return 7;
}
