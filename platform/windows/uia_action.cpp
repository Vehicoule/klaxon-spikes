// uia_action.cpp — driver d'actions UIA de vérification (lot UIA-2).
// Cherche un élément par sous-chaîne de Name dans le RawView de la fenêtre
// "Klaxon Gallery" et exécute :
//   uia_action.exe --select <name>    → SelectionItemPattern.Select()
//   uia_action.exe --invoke <name>    → InvokePattern.Invoke()
//   uia_action.exe --range <name> <v> → RangeValuePattern.SetValue(v)
//   uia_action.exe --focus <name>     → IUIAutomationElement::SetFocus()
// Sortie : JSON {action, name, aid, ok, detail}.

#include <windows.h>
#include <uiautomationclient.h>
#include <uiautomationcore.h>
#include <uiautomation.h>
#include <stdio.h>
#include <string>
#include <vector>

static IUIAutomationElement* g_hit = nullptr;
static BSTR g_hit_aid = nullptr;

static void findByName(IUIAutomation* uia, IUIAutomationElement* el,
                       const wchar_t* needle, int depth) {
    if (!el || g_hit || depth > 20) return;
    BSTR name = nullptr;
    el->get_CurrentName(&name);
    if (name && wcsstr(name, needle)) {
        el->get_CurrentAutomationId(&g_hit_aid);
        g_hit = el;
        g_hit->AddRef();
        SysFreeString(name);
        return;
    }
    SysFreeString(name);
    IUIAutomationTreeWalker* tw = nullptr;
    uia->get_RawViewWalker(&tw);
    if (!tw) return;
    IUIAutomationElement* child = nullptr;
    if (SUCCEEDED(tw->GetFirstChildElement(el, &child)) && child) {
        while (child && !g_hit) {
            findByName(uia, child, needle, depth + 1);
            IUIAutomationElement* next = nullptr;
            tw->GetNextSiblingElement(child, &next);
            child->Release();
            child = next;
        }
    }
    tw->Release();
}

int wmain(int argc, wchar_t** argv) {
    const wchar_t* action = argc > 1 ? argv[1] : L"";
    const wchar_t* name = argc > 2 ? argv[2] : L"";
    double rval = argc > 3 ? wcstod(argv[3], nullptr) : 0.0;

    HWND hwnd = FindWindowW(nullptr, L"Klaxon Gallery");
    if (!hwnd) {
        printf("{\"tool\":\"kx-uia-action\",\"error\":\"window not found\"}\n");
        return 2;
    }
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IUIAutomation* uia = nullptr;
    CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                     IID_IUIAutomation, (void**)&uia);
    IUIAutomationElement* root = nullptr;
    uia->ElementFromHandle(hwnd, &root);
    if (!root) {
        printf("{\"tool\":\"kx-uia-action\",\"error\":\"ElementFromHandle fail\"}\n");
        return 5;
    }
    findByName(uia, root, name, 0);
    if (!g_hit) {
        printf("{\"tool\":\"kx-uia-action\",\"action\":\"%ls\",\"name\":\"%ls\",\"ok\":0,\"detail\":\"element not found\"}\n",
               action, name);
        return 6;
    }
    HRESULT hr = E_FAIL;
    const wchar_t* detail = L"";
    if (!wcscmp(action, L"--select")) {
        IUIAutomationSelectionItemPattern* p = nullptr;
        hr = g_hit->GetCurrentPatternAs(UIA_SelectionItemPatternId,
              IID_IUIAutomationSelectionItemPattern, (void**)&p);
        if (SUCCEEDED(hr) && p) { hr = p->Select(); p->Release(); }
        detail = L"SelectionItem.Select";
    } else if (!wcscmp(action, L"--invoke")) {
        IUIAutomationInvokePattern* p = nullptr;
        hr = g_hit->GetCurrentPatternAs(UIA_InvokePatternId,
              IID_IUIAutomationInvokePattern, (void**)&p);
        if (SUCCEEDED(hr) && p) { hr = p->Invoke(); p->Release(); }
        detail = L"InvokePattern.Invoke";
    } else if (!wcscmp(action, L"--range")) {
        IUIAutomationRangeValuePattern* p = nullptr;
        hr = g_hit->GetCurrentPatternAs(UIA_RangeValuePatternId,
              IID_IUIAutomationRangeValuePattern, (void**)&p);
        if (SUCCEEDED(hr) && p) { hr = p->SetValue(rval); p->Release(); }
        detail = L"RangeValue.SetValue";
    } else if (!wcscmp(action, L"--focus")) {
        hr = g_hit->SetFocus();
        detail = L"SetFocus";
    } else {
        printf("{\"tool\":\"kx-uia-action\",\"error\":\"unknown action\"}\n");
        return 7;
    }
    printf("{\"tool\":\"kx-uia-action\",\"action\":\"%ls\",\"name\":\"%ls\",\"aid\":\"%ls\",\"hr\":\"0x%08lx\",\"ok\":%d,\"detail\":\"%ls\"}\n",
           action, name, g_hit_aid ? g_hit_aid : L"", (unsigned long)hr,
           SUCCEEDED(hr) ? 1 : 0, detail);
    g_hit->Release();
    root->Release();
    uia->Release();
    CoUninitialize();
    return SUCCEEDED(hr) ? 0 : 8;
}
