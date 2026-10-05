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
          { id: 'distant', type: 'rectangle', x: 3000, y: 3000, width: 200, height: 100 },
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
    // First opens fit content; reloads restore the user's zoom and pan.
    const assertSceneVisible = () => page.waitForFunction(() => {
      const api = window.__api;
      if (api?.getSceneElements().length !== 2) return false;
      const state = api.getAppState();
      return api.getSceneElements().every(element => {
        const x = (element.x + element.width / 2 + state.scrollX) * state.zoom.value;
        const y = (element.y + element.height / 2 + state.scrollY) * state.zoom.value;
        return x > 0 && x < state.width && y > 0 && y < state.height;
      });
    });
    await page.goto(`${origin}?token=test`);
    await assertSceneVisible();
    const savedView = { scrollX: -4900, scrollY: -4800, zoom: { value: 1.5 } };
    await page.evaluate(view => window.__api.updateScene({ appState: view }), savedView);
    await page.waitForFunction(({ key, view }) => localStorage.getItem(key) === JSON.stringify(view),
      { key: `excalimacs-view:${baseLink}`, view: { zoom: savedView.zoom, scrollX: savedView.scrollX, scrollY: savedView.scrollY } });
    await page.reload();
    await page.waitForFunction(view => {
      const state = window.__api?.getAppState();
      return state?.zoom.value === view.zoom.value && state.scrollX === view.scrollX && state.scrollY === view.scrollY;
    }, savedView);
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
    await assertSceneVisible();
    assert.deepEqual(errors, []);
    console.log('Initial/reloaded viewport, focused element/group opening, clipboard links, and missing-target fallback passed.');
  } finally {
    await browser?.close();
    await server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
