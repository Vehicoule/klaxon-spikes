// run_w0.mjs — test navigateur W0 : lance Chrome for Testing headless,
// pilote ?backend=webgpu|webgl, attend __RESULTS, écrit results/*.json + png.
// Usage: node test/run_w0.mjs <backend> [--no-webgpu]
import { chromium } from 'playwright-core';
import { mkdirSync, writeFileSync } from 'fs';

const backend = process.argv[2] || 'webgpu';
const noWebgpu = process.argv.includes('--no-webgpu');
const chromePath = '/home/ubuntu/.local/bin/google-chrome';
const url = `http://127.0.0.1:8093/app/index.html?backend=${backend}`;

const args = [
    '--no-sandbox',
    '--use-gl=angle', '--use-angle=swiftshader',
];
if (backend === 'webgpu' && !noWebgpu) {
    args.push('--enable-unsafe-webgpu', '--use-webgpu-adapter=swiftshader',
              '--enable-features=Vulkan');
}

const browser = await chromium.launch({
    executablePath: chromePath,
    headless: true,
    args,
});
const page = await browser.newPage({ viewport: { width: 560, height: 900 } });
page.on('console', m => {
    const t = m.text();
    if (!t.includes('GroupMarkerNotSet') && !t.includes('Automatic fallback to software'))
        console.log('[console]', t);
});
page.on('pageerror', e => console.log('[pageerror]', e));

await page.goto(url, { waitUntil: 'load', timeout: 30000 });

let results = null;
const t0 = Date.now();
while (Date.now() - t0 < 300000) {
    results = await page.evaluate(() => window.__RESULTS);
    if (results && (results.status === 'PASS' || results.status === 'FAIL')) break;
    if (results && results.status !== 'BOOTING' && results.status !== 'RUNNING') break;
    await page.waitForTimeout(500);
}

if (!results) { console.error('TIMEOUT: no __RESULTS'); await browser.close(); process.exit(2); }

mkdirSync('test/results', { recursive: true });
const tag = noWebgpu ? `${backend}-noac` : backend;
const out = `test/results/w0-${tag}.json`;
writeFileSync(out, JSON.stringify(results, null, 2));
await page.screenshot({ path: `test/results/w0-${tag}.png`, fullPage: true });
console.log(`== ${backend}: status=${results.status} errors=${JSON.stringify(results.errors)}`);
if (results.scenes) {
    for (const [k, v] of Object.entries(results.scenes))
        console.log(`   ${k}: mae=${v.mae} bench=${v.bench_ms}ms raster=${v.raster_bench_ms}ms`);
}
await browser.close();
process.exit(results.status === 'PASS' ? 0 : 1);
