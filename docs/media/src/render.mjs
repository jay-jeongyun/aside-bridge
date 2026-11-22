#!/usr/bin/env node
// Frame-exact renderer for the README demo and the social preview.
//
//   node docs/media/src/render.mjs            # demo frames + demo.mp4 + demo.gif + social-preview.png
//   node docs/media/src/render.mjs social     # only social-preview.png
//
// Needs: Node 18+, playwright-core (or playwright) resolvable from here or via PLAYWRIGHT_CORE,
// a Chromium build (CHROME_PATH, or Playwright's cached chromium), ffmpeg (FFMPEG or PATH).
// GSAP is loaded from the jsDelivr CDN in the HTML; set GSAP_JS to a local gsap.min.js to
// render offline. The timeline is paused and stepped with window.__seek(t), so output does
// not depend on real-time playback speed.
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const mediaDir = path.resolve(here, '..');
const mode = process.argv[2] || 'all';

function load(name) {
  const cands = [process.env.PLAYWRIGHT_CORE, name].filter(Boolean);
  for (const c of cands) { try { return require(c); } catch {} }
  return null;
}
const pw = load('playwright-core') || load('playwright');
if (!pw) { console.error('playwright-core not found (npm i playwright-core, or set PLAYWRIGHT_CORE)'); process.exit(1); }

function findChrome() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
  if (fs.existsSync(cache)) {
    const dirs = fs.readdirSync(cache).filter((d) => d.startsWith('chromium_headless_shell-')).sort().reverse();
    for (const d of dirs) {
      for (const sub of fs.readdirSync(path.join(cache, d))) {
        const p = path.join(cache, d, sub, 'chrome-headless-shell');
        if (fs.existsSync(p)) return p;
      }
    }
  }
  const mac = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  return fs.existsSync(mac) ? mac : undefined; // undefined: let Playwright pick its default
}
const ffmpeg = process.env.FFMPEG || (fs.existsSync('/opt/homebrew/bin/ffmpeg') ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg');

// tiny static server (avoids file:// quirks)
const server = http.createServer((req, res) => {
  const f = path.join(here, decodeURIComponent(req.url.split('?')[0]));
  if (!f.startsWith(here) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

const browser = await pw.chromium.launch({ executablePath: findChrome(), args: ['--font-render-hinting=none'] });

async function newPage(w, h) {
  const page = await browser.newPage({ viewport: { width: w, height: h }, deviceScaleFactor: 1 });
  let gsapLocal = process.env.GSAP_JS;
  if (!gsapLocal) { try { gsapLocal = path.join(path.dirname(require.resolve('gsap/package.json')), 'dist/gsap.min.js'); } catch {} }
  if (gsapLocal && fs.existsSync(gsapLocal)) {
    await page.route(/cdn\.jsdelivr\.net\/npm\/gsap@.*gsap\.min\.js/, (route) =>
      route.fulfill({ contentType: 'application/javascript', body: fs.readFileSync(gsapLocal) }));
  }
  return page;
}

async function social() {
  const page = await newPage(1280, 640);
  await page.goto(`${base}/social.html`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  const out = path.join(mediaDir, 'social-preview.png');
  await page.screenshot({ path: out });
  await page.close();
  console.log('wrote', out);
}

async function demo() {
  const fps = 30;
  const page = await newPage(1200, 660);
  await page.goto(`${base}/scene.html`, { waitUntil: 'load' });
  await page.waitForFunction(() => window.__ready === true);
  await page.evaluate(() => document.fonts.ready);
  const dur = await page.evaluate(() => window.__duration);
  const frames = fs.mkdtempSync(path.join(os.tmpdir(), 'asb-frames-'));
  const n = Math.round(dur * fps);
  for (let i = 0; i < n; i++) {
    await page.evaluate((t) => window.__seek(t), i / fps);
    await page.screenshot({ path: path.join(frames, `f${String(i).padStart(4, '0')}.png`) });
  }
  await page.close();
  console.log(`captured ${n} frames in ${frames}`);

  const mp4 = path.join(mediaDir, 'demo.mp4');
  execFileSync(ffmpeg, ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(frames, 'f%04d.png'),
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', mp4]);
  console.log('wrote', mp4);

  const gif = path.join(mediaDir, 'demo.gif');
  const gifFps = process.env.GIF_FPS || '15';
  const filt = `fps=${gifFps},split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`;
  execFileSync(ffmpeg, ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(frames, 'f%04d.png'),
    '-filter_complex', filt, '-loop', '0', gif]);
  console.log('wrote', gif);
  if (!process.env.KEEP_FRAMES) fs.rmSync(frames, { recursive: true, force: true });
}

// preview: node render.mjs preview 0,3,7 /tmp/out  -> stills at those seconds (rendered in order)
async function preview() {
  const times = (process.argv[3] || '0,3,6,9,12,14.5').split(',').map(Number).sort((a, b) => a - b);
  const outDir = process.argv[4] || os.tmpdir();
  const page = await newPage(1200, 660);
  await page.goto(`${base}/scene.html`, { waitUntil: 'load' });
  await page.waitForFunction(() => window.__ready === true);
  for (let t = 0, k = 0; k < times.length; t += 1 / 30) {
    await page.evaluate((x) => window.__seek(x), t);
    if (t + 1e-6 >= times[k]) { await page.screenshot({ path: path.join(outDir, `still_${times[k]}.png`) }); k++; }
  }
  await page.close();
}

try {
  if (mode === 'preview') await preview();
  if (mode === 'all' || mode === 'demo') await demo();
  if (mode === 'all' || mode === 'social') await social();
} finally {
  await browser.close();
  server.close();
}
