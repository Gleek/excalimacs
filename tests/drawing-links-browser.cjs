// Requires Playwright; supports PLAYWRIGHT_MODULE and CHROMIUM_PATH.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const root = require('node:path').resolve(__dirname, '..');

(async () => {
  const { createServer } = await import(root + '/node_modules/vite/dist/node/index.js');
  const server = await createServer({ root, server: { port: 0, host: '127.0.0.1' } });
  await server.listen();
  let browser;
  try {
    browser = await chromium.launch(process.env.CHROMIUM_PATH
      ? { executablePath: process.env.CHROMIUM_PATH } : {});
    const context = await browser.newContext({ permissions: ['clipboard-read', 'clipboard-write'] });
    const page = await context.newPage({ viewport: { width: 1400, height: 900 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const baseLink = 'excalimacs:%2Ftmp%2Fdiagram.excalidraw.png';
    await page.route('**/api/**', route => {
      const endpoint = new URL(route.request().url()).pathname;
      const data = {
        '/api/drawing': { drawing: { elements: [
          { id: 'target', type: 'rectangle', x: 5000, y: 5000, width: 200, height: 100, groupIds: ['group'] },
          { id: 'distant', type: 'rectangle', x: -5000, y: -5000, width: 200, height: 100 },
        ], appState: {}, files: {} }, hash: 'test', name: 'diagram.excalidraw.png', format: 'png' },
        '/api/link': { link: baseLink },
        '/api/plugins': { plugins: [], settings: {} },
        '/api/library-token': { token: 'library' },
        '/api/library': { library: { libraryItems: [] }, hash: 'library' },
      }[endpoint] || {};
      return route.fulfill({ json: data });
    });
    await page.route('**/src/main.jsx', async route => {
      const response = await route.fetch();
      const body = (await response.text()).replace('onExcalidrawAPI: setExcalidrawAPI',
        'onExcalidrawAPI: (api) => { window.__api = api; setExcalidrawAPI(api); }');
      await route.fulfill({ response, body });
    });
    const origin = server.resolvedUrls.local[0];
    for (const target of ['element=target', 'group=group']) {
      await page.goto(`${origin}?token=test&case=${target}#${target}`);
      await page.waitForFunction(() => window.__api?.getSceneElements().length === 2);
      await page.waitForFunction(() => {
        const state = window.__api.getAppState();
        const x = (5100 + state.scrollX) * state.zoom.value;
        const y = (5050 + state.scrollY) * state.zoom.value;
        return x > 100 && x < 1300 && y > 100 && y < 800;
      });
    }
    const center = await page.evaluate(() => {
      const api = window.__api;
      api.updateScene({ appState: { selectedElementIds: { target: true } } });
      const state = api.getAppState();
      return [(5100 + state.scrollX) * state.zoom.value,
        (5050 + state.scrollY) * state.zoom.value];
    });
    await page.mouse.click(...center, { button: 'right' });
    await page.getByText('Copy link to object', { exact: true }).click();
    await page.waitForFunction(() => navigator.clipboard.readText().then(text => text.startsWith('excalimacs:')));
    assert.equal(await page.evaluate(() => navigator.clipboard.readText()), `${baseLink}#element=target`);
    await page.goto(`${origin}?token=test&case=missing#element=missing`);
    await page.getByRole('alert').filter({ hasText: 'no longer exists' }).waitFor();
    assert.deepEqual(errors, []);
    console.log('Focused element/group opening, whole-scene preservation, clipboard links, and missing-target notice passed.');
  } finally {
    await browser?.close();
    await server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
