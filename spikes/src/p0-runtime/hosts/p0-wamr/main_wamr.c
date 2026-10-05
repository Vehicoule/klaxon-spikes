// main_wamr.c — harnais P0 WAMR fast-interp (metering via instruction count)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>
#include "wasm_export.h"

static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int next_handle = 1;

/* vh_host.request(ptr,len) -> i32 : signature "(~i)i" = * + length following */
static int host_request(wasm_exec_env_t env, int32_t ptr, int32_t len) {
    (void)ptr; (void)len; (void)env;
    return next_handle++;
}
static int host_read(wasm_exec_env_t env, int32_t h, int32_t ptr, int32_t cap) {
    (void)env; (void)h; (void)ptr; (void)cap; return 0;
}
static int host_release(wasm_exec_env_t env, int32_t h) {
    (void)env; (void)h; return 0;
}

static NativeSymbol natives[] = {
    { "request", host_request, "(ii)i", NULL },
    { "read", host_read, "(iii)i", NULL },
    { "release", host_release, "(i)i", NULL },
};

static wasm_module_inst_t g_inst = NULL;  /* pour le test d'annulation */

static void *cancel_thread(void *arg) {
    (void)arg;
    usleep(200 * 1000);                     /* 200 ms puis terminate */
    if (g_inst) wasm_runtime_terminate(g_inst);
    return NULL;
}

static unsigned char *read_file(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc(*n);
    fread(b, 1, *n, f); fclose(f); return b;
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "../../plugin/wasm";
    const char *only = argc > 2 ? argv[2] : NULL;

    RuntimeInitArgs init_args;
    memset(&init_args, 0, sizeof(init_args));
    init_args.mem_alloc_type = Alloc_With_System_Allocator;
    if (!wasm_runtime_full_init(&init_args)) { fprintf(stderr, "init fail\n"); return 1; }
    if (!wasm_runtime_register_natives("vh_host", natives, 3)) {
        fprintf(stderr, "natives fail\n"); return 1;
    }

    struct { const char *name, *path; int fuel; } cases[] = {
        { "toy", "toy.wasm", 200000000 },
        { "loop", "hostiles.wasm", 5000000 },
        { "mem", "hostile_mem.wasm", 200000000 },
        { "recursion", "hostile_rec.wasm", 50000 },
        { "table1M", "hostile_table.wasm", 200000000 },
        { "edge64", "edge_mem64.wasm", 200000000 },
    };

    printf("{");
    int first = 1;
    for (unsigned i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
        if (only && strcmp(only, cases[i].name)) continue;
        if (!first) printf(","); first = 0;
        char path[512]; snprintf(path, sizeof path, "%s/%s", dir, cases[i].path);
        size_t n; unsigned char *buf = read_file(path, &n);
        if (!buf) { printf("\"%s\":{\"error\":\"read\"}", cases[i].name); continue; }

        char err[256] = {0};
        double t0 = now_ms();
        wasm_module_t mod = wasm_runtime_load(buf, n, err, sizeof err);
        if (!mod) {
            printf("\"%s\":{\"status\":\"load_fail\",\"reason\":\"%s\"}", cases[i].name, err);
            free(buf); continue;
        }
        /* limites hôte : stack 64Kio, heap 0 (mémoire guest uniquement) */
        wasm_module_inst_t inst = wasm_runtime_instantiate(mod, 64 * 1024, 0, err, sizeof err);
        if (!inst) {
            printf("\"%s\":{\"status\":\"instantiate_fail\",\"reason\":\"%s\"}", cases[i].name, err);
            wasm_runtime_unload(mod); free(buf); continue;
        }
        g_inst = inst;
        double inst_ms = now_ms() - t0;

        wasm_function_inst_t fn = wasm_runtime_lookup_function(inst, "vh_call");
        if (!fn) { printf("\"%s\":{\"status\":\"noexport\"}", cases[i].name); continue; }
        wasm_exec_env_t env = wasm_runtime_create_exec_env(inst, 64 * 1024);
        wasm_runtime_set_instruction_count_limit(env, cases[i].fuel);

        /* test d'annulation cross-thread sur les cas hostiles */
        pthread_t killer; int have_killer = 0;
        if (!strcmp(cases[i].name, "NONE")) {
            pthread_create(&killer, NULL, cancel_thread, NULL); have_killer = 1;
        }

        uint32_t args[2] = { 0, 0 };
        t0 = now_ms();
        int ok = wasm_runtime_call_wasm(env, fn, 2, args);
        double call_ms = now_ms() - t0;
        if (have_killer) pthread_join(killer, NULL);

        if (ok) {
            uint64_t ret = ((uint64_t)args[1] << 32) | args[0];
            /* wasm_runtime_call_wasm retourne : args[0] = retval bas */
            uint32_t plen = (uint32_t)(ret >> 32), pptr = (uint32_t)ret;
            uint32_t mem_sz = (uint32_t)wasm_runtime_get_app_addr_range(inst, pptr, NULL, NULL) ?
                                  0 : 0;
            bool valid = wasm_runtime_validate_app_addr(inst, pptr, plen);
            printf("\"%s\":{\"status\":\"ok\",\"inst_ms\":%.2f,\"call_ms\":%.2f,"
                   "\"ret_len\":%u,\"ret_valid\":%s}",
                   cases[i].name, inst_ms, call_ms, plen, valid ? "true" : "false");
            (void)mem_sz;
        } else {
            const char *e2 = wasm_runtime_get_exception(inst);
            printf("\"%s\":{\"status\":\"trap\",\"trap\":\"%s\",\"inst_ms\":%.2f,\"call_ms\":%.2f}",
                   cases[i].name, e2 ? e2 : "?", inst_ms, call_ms);
        }
        wasm_runtime_destroy_exec_env(env);
        wasm_runtime_deinstantiate(inst);
        wasm_runtime_unload(mod);
        free(buf);
        g_inst = NULL;
    }
    printf("}\n");
    wasm_runtime_destroy();
    return 0;
}
