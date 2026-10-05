// uia_dump.cpp — client UIA de vérification K3-a11y : dump l'arbre
// d'automatisation de la fenêtre "Klaxon Gallery" (ou hwnd en arg) :
// Name, ControlType, BoundingRectangle, IsEnabled, IsKeyboardFocusable,
// HasKeyboardFocus, LocalizedControlType, IsSelected (SelectionItemPattern).
// Usage : uia_dump.exe [hwnd_hex]   (défaut : FindWindow par titre)

#include <windows.h>
#include <uiautomationclient.h>
#include <uiautomationcore.h>
#include <uiautomation.h>
#include <stdio.h>
#include <string>

static const wchar_t* ctName(long id) {
    switch (id) {
        case UIA_ButtonControlTypeId: return L"Button";
        case UIA_CheckBoxControlTypeId: return L"CheckBox";
        case UIA_EditControlTypeId: return L"Edit";
        case UIA_SliderControlTypeId: return L"Slider";
        case UIA_ListControlTypeId: return L"List";
        case UIA_ListItemControlTypeId: return L"ListItem";
        case UIA_GroupControlTypeId: return L"Group";
        case UIA_PaneControlTypeId: return L"Pane";
        case UIA_TextControlTypeId: return L"Text";
        case UIA_CustomControlTypeId: return L"Custom";
        case UIA_WindowControlTypeId: return L"Window";
        default: return L"?";
    }
}

static void wsPrint(const wchar_t* prefix, BSTR s) {
    printf("%ls%ls\n", prefix, s ? s : L"");
}

static int g_count = 0;
static int dumpEl(IUIAutomation* uia, IUIAutomationElement* el, int depth) {
    if (!el || g_count >= 500) return 0;
    g_count++;

    BSTR name = nullptr, lct = nullptr;
    el->get_CurrentName(&name);
    CONTROLTYPEID ct = 0;
    el->get_CurrentControlType(&ct);
    RECT rc = {};
    el->get_CurrentBoundingRectangle(&rc);
    BOOL en = 0, kf = 0, hf = 0;
    el->get_CurrentIsEnabled(&en);
    el->get_CurrentIsKeyboardFocusable(&kf);
    el->get_CurrentHasKeyboardFocus(&hf);
    el->get_CurrentLocalizedControlType(&lct);
    BOOL sel = -1;
    IUIAutomationSelectionItemPattern* sip = nullptr;
    if (SUCCEEDED(el->GetCurrentPatternAs(UIA_SelectionItemPatternId,
                                          IID_IUIAutomationSelectionItemPattern,
                                          (void**)&sip)) && sip) {
        sip->get_CurrentIsSelected(&sel);
        sip->Release();
    }

    for (int i = 0; i < depth; ++i) printf("  ");
    printf("[%3d] %-8ls name=\"%S\" bounds=%ld,%ld %ldx%ld en=%d kf=%d focus=%d",
           g_count, ctName(ct), name ? name : L"", rc.left, rc.top,
           rc.right - rc.left, rc.bottom - rc.top, en, kf, hf);
    if (sel >= 0) printf(" sel=%d", sel);
    if (lct && *lct) printf(" lct=\"%S\"", lct);
    if (depth == 0) {
        BSTR pd = nullptr;
        el->get_CurrentProviderDescription(&pd);
        if (pd) printf("\n      ProviderDescription=");
        printf("%S\n", pd ? pd : L"");
        SysFreeString(pd);
        BSTR cls = nullptr;
        el->get_CurrentClassName(&cls);
        printf("      ClassName=\"%S\"\n", cls ? cls : L"");
        SysFreeString(cls);
    }
    printf("\n");
    SysFreeString(name); SysFreeString(lct);

    // Enfants via TreeWalker (RawView — inclut les éléments non-control)
    IUIAutomationTreeWalker* tw = nullptr;
    uia->get_RawViewWalker(&tw);
    if (!tw) return 0;
    IUIAutomationElement* child = nullptr;
    if (SUCCEEDED(tw->GetFirstChildElement(el, &child)) && child) {
        while (child) {
            dumpEl(uia, child, depth + 1);
            IUIAutomationElement* next = nullptr;
            tw->GetNextSiblingElement(child, &next);
            child->Release();
            child = next;
        }
    }
    tw->Release();
    return g_count;
}

int wmain(int argc, wchar_t** argv) {
    HWND hwnd = nullptr;
    if (argc > 1) {
        hwnd = (HWND)(uintptr_t)wcstoul(argv[1], nullptr, 0);
    } else {
        hwnd = FindWindowW(nullptr, L"Klaxon Gallery");
    }
    if (!hwnd) {
        printf("{\"tool\":\"kx-uia-dump\",\"error\":\"window not found\"}\n");
        return 2;
    }
    printf("hwnd=%p\n", hwnd);

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) { printf("CoInit fail %08lx\n", hr); return 3; }

    IUIAutomation* uia = nullptr;
    hr = CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                          IID_IUIAutomation, (void**)&uia);
    if (FAILED(hr) || !uia) { printf("CUIAutomation fail %08lx\n", hr); return 4; }

    IUIAutomationElement* root = nullptr;
    hr = uia->ElementFromHandle(hwnd, &root);
    if (FAILED(hr) || !root) {
        printf("{\"tool\":\"kx-uia-dump\",\"error\":\"ElementFromHandle fail %08lx\"}\n", hr);
        return 5;
    }

    g_count = 0;
    dumpEl(uia, root, 0);
    root->Release();
    uia->Release();
    CoUninitialize();

    printf("{\"tool\":\"kx-uia-dump\",\"hwnd\":\"%p\",\"nodes\":%d}\n", hwnd, g_count);
    return g_count > 1 ? 0 : 6;   // >1 = arbre réel (root + enfants)
}
