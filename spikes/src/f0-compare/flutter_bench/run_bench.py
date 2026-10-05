#!/usr/bin/env python3
"""Drive the running Chrome (CDP :29229) through the flutter bench pages,
scrape #result JSON per scene, write out/f0-flutter-sN.json."""
import asyncio, json, os, sys
from playwright.async_api import async_playwright

OUT = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)
SCENES = [1, 2, 3, 4, 6, 8]
BASE = "http://localhost:18790/"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.connect_over_cdp("http://localhost:29229")
        ctx = await browser.new_context()  # fresh: évite le service-worker cache
        page = await ctx.new_page()
        for s in SCENES:
            try:
                await page.goto(f"{BASE}?scene={s}", wait_until="load")
                await page.wait_for_selector("#result:not(:empty)", timeout=90000)
                txt = await page.inner_text("#result")
                data = json.loads(txt)
                with open(f"{OUT}/f0-flutter-s{s}.json", "w") as f:
                    f.write(json.dumps(data))
                print(f"s{s}: {txt.strip()}")
            except Exception as e:
                print(f"s{s}: FAIL {e}")
        await page.close()
        await browser.close()

asyncio.run(main())
