// app.js — harnais W0 : init device WebGPU, fontes, puis boucle rAF pilotant
// la machine à états Zig (scène → bench → readback → MAE → suivante).
/* global Module, navigator, requestAnimationFrame, window, document, performance */

var Module = typeof Module !== 'undefined' ? Module : {};

(function () {
    'use strict';

    var FONTS = [
        '../assets/fonts/Roboto-Regular.ttf',
        '../assets/fonts/NotoNaskhArabic-VF.ttf',
        '../assets/fonts/NotoSansCJK-VF-subset.otf.ttc',
        '../assets/fonts/NotoColorEmoji-Regular.ttf',
    ];

    var results = {
        status: 'BOOTING', backend: null, driver: null,
        scenes: {}, fonts: 0, errors: [],
        init_ms: 0, first_frame_ms: 0, started: performance.now(),
    };
    window.__RESULTS = results;

    function params() {
        return new URLSearchParams(window.location.search);
    }

    function backendKind() {
        var b = params().get('backend') || 'webgpu';
        if (b === 'webgl') return 1;
        if (b === 'webgpu') return 2;
        return 2;
    }
    results.backend = params().get('backend') || 'webgpu';

    function out(s) {
        var el = document.getElementById('out');
        if (el) el.textContent += s + '\n';
    }

    function collect(tag, json) {
        try {
            var j = JSON.parse(json);
            if (tag === 'bench') {
                results.scenes['s' + j.scene] = results.scenes['s' + j.scene] || {};
                results.scenes['s' + j.scene].bench_ms = j.bench_ms;
                results.scenes['s' + j.scene].raster_bench_ms = j.raster_bench_ms;
            } else if (tag === 'mae') {
                results.scenes['s' + j.scene] = results.scenes['s' + j.scene] || {};
                for (var k in j) if (k !== 'scene') results.scenes['s' + j.scene][k] = j[k];
                if (results.status === 'RUNNING' && !results.first_frame_ms) {
                    results.first_frame_ms = performance.now() - results.started;
                }
            } else if (tag === 'done') {
                results.status = j.status;
                results.driver = j.driver;
                results.fonts = j.fonts;
            } else if (tag === 'draw_smoke') {
                results.draw_smoke = j;
            } else if (tag === 'error') {
                results.errors.push(j.what || json);
                results.status = 'FAIL';
            } else if (tag === 'backend') {
                results.status = j.status;
                results.errors.push(j.reason || '');
            }
            out(tag + ' ' + json);
            console.log('KX ' + tag + ' ' + json);
        } catch (e) {
            results.errors.push('report parse: ' + e);
        }
    }

    function pump() {
        // 1) poll du readback courant
        var rc = Module._kx_poll_readback();
        if (rc === 0) { requestAnimationFrame(pump); return; }
        if (rc < 0) {
            results.status = 'FAIL';
            results.errors.push('readback failed rc=' + rc);
            return;
        }
        // 2) readback fini → scène suivante
        var step = Module._kx_step();
        if (step === 0) { requestAnimationFrame(pump); return; }
        if (step === 1) {
            if (results.status === 'RUNNING') results.status = 'PASS';
            return;
        }
        results.status = 'FAIL';
        results.errors.push('step rc=' + step);
    }

    function loadFonts() {
        return Promise.all(FONTS.map(function (url) {
            return fetch(url).then(function (r) {
                if (!r.ok) throw new Error('font fetch ' + url + ' ' + r.status);
                return r.arrayBuffer();
            }).then(function (ab) {
                var bytes = new Uint8Array(ab);
                var ptr = Module._kx_alloc(bytes.length);
                Module.HEAPU8.set(bytes, ptr);
                var rc = Module._kx_add_font(ptr, bytes.length);
                Module._kx_free_alloc(ptr);
                if (rc < 0) throw new Error('kx_add_font ' + url + ' rc=' + rc);
                return url.split('/').pop();
            });
        }));
    }

    Module['onKxReport'] = collect;

    Module['preRun'] = Module['preRun'] || [];
    Module['onRuntimeInitialized'] = function () {
        var kind = backendKind();
        var ready = Promise.resolve();
        if (kind === 2) {
            ready = (async function () {
                if (!navigator.gpu) throw new Error('navigator.gpu absent (WebGPU désactivé)');
                var adapter = await navigator.gpu.requestAdapter();
                if (!adapter) throw new Error('requestAdapter → null');
                var device = await adapter.requestDevice();
                // emdawnwebgpu : le port lit Module['preinitializedWebGPUDevice'].
                Module['preinitializedWebGPUDevice'] = device;
            })();
        }
        ready.then(function () {
            return loadFonts();
        }).then(function (names) {
            out('fonts: ' + names.join(', '));
            results.status = 'RUNNING';
            var rc = Module._kx_start(kind);
            if (rc !== 0) {
                results.status = results.status === 'FAIL' ? 'FAIL' : 'FAIL';
                results.errors.push('kx_start rc=' + rc);
                return;
            }
            // Canvas : dessine la scène composite en visuel (témoin) — laisse la
            // pompe rAF piloter les 9 scènes bench+MAE en offscreen.
            requestAnimationFrame(pump);
        }).catch(function (e) {
            results.status = 'FAIL';
            results.errors.push(String(e && e.message || e));
            out('init error: ' + e);
        });
    };
})();
