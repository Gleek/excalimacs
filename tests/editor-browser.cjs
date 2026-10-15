// Regression tests using the real editor with a disposable HTTP API.
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
    const errors = [];
    async function pageWithAPI(blockStorage = false) {
      const page = await browser.newPage();
      page.on('pageerror', error => errors.push(error.message));
      if (blockStorage) await page.addInitScript(() => {
        Object.defineProperty(window, 'localStorage', {
          get() { throw new DOMException('Storage blocked', 'SecurityError'); },
        });
      });
      await page.route('**/api/**', route => route.fulfill({ json: {
        '/api/drawing': { drawing: { elements: [], appState: {}, files: {} },
          hash: 'test', name: 'test.excalidraw', format: 'json' },
        '/api/link': { link: 'excalimacs:/tmp/test.excalidraw' },
        '/api/plugins': { plugins: [], settings: {} },
        '/api/library-token': { token: 'library' },
        '/api/library': { library: { libraryItems: [] }, hash: null },
      }[new URL(route.request().url()).pathname] || {} }));
      await page.route('**/src/main.jsx', async route => {
        const response = await route.fetch();
        const body = (await response.text()).replace('onExcalidrawAPI: setExcalidrawAPI',
          'onExcalidrawAPI: (api) => { window.__api = api; setExcalidrawAPI(api); }');
        await route.fulfill({ response, body });
      });
      return page;
    }
    const page = await pageWithAPI();
    const origin = server.resolvedUrls.local[0];
    await page.goto(`${origin}?token=test`);
    await page.waitForFunction(() => window.__api);
    const results = await page.evaluate(async () => {
      const { runAgentOp } = await import('/src/agent.js');
      const api = window.__api;
      const run = (op, payload) => runAgentOp(api, async () => {}, {
        op, payload: typeof payload === 'string' ? payload : JSON.stringify(payload),
      });
      const added = await run('add', [
        { id: 'box', type: 'rectangle', x: 100, y: 100, width: 120, height: 100, label: { text: 'Clear box' } },
        { id: 'arrow', type: 'arrow', x: 300, y: 100, points: [[0, 0], [100, 0]], label: { text: 'Clear arrow' } },
        { id: 'text', type: 'text', x: 100, y: 300, text: 'Clear text' },
      ]);
      if (added.error) throw new Error(added.error);
      const cleared = await run('update', added.result.map(({ id, version }) => ({ id, version, text: '' })));
      const labels = api.getSceneElements().filter(e => e.containerId);
      const shape = (await run('scene')).result.find(e => e.id === 'box');
      api.updateScene({ elements: api.getSceneElementsIncludingDeleted().map(e => e.id === 'box'
        ? { ...e, angle: Math.PI / 4, version: e.version + 1, versionNonce: 12345 } : e) });
      const deletion = await run('delete', `box@${shape.version}`);
      // Field-level updates still permit an unrelated human change.
      const update = await run('update', [{ id: 'box', version: shape.version, backgroundColor: '#a5d8ff' }]);
      const box = api.getSceneElements().find(e => e.id === 'box');
      const freshDelete = await run('delete', `box@${update.result?.[0].version}`);
      return { cleared, labels: labels.length, deletion, update, angle: box.angle,
        freshDelete, remaining: api.getSceneElements().map(e => e.id) };
    });
    assert.ok(results.cleared.result, JSON.stringify(results.cleared));
    assert.equal(results.labels, 0, 'clearing labels removes their text elements');
    assert.ok(results.deletion.current, 'stale deletion detects human rotation');
    assert.ok(results.update.result, 'unrelated updates still merge');
    assert.equal(results.angle, Math.PI / 4);
    assert.ok(results.freshDelete.result);
    assert.ok(!results.remaining.includes('box'));

    const blocked = await pageWithAPI(true);
    await blocked.goto(`${origin}?token=test`);
    await blocked.waitForFunction(() => window.__api);
    await blocked.goto(`${origin}?libraryToken=library#addLibrary=${encodeURIComponent('https://libraries.excalidraw.com/libraries/test/test.excalidrawlib')}`);
    await blocked.getByText('Library added. Return to your Excalimacs editor.', { exact: true }).waitFor();
    assert.deepEqual(errors, []);
    console.log('Stale deletion, empty labels, unrelated updates, and unavailable browser storage passed.');
  } finally {
    await browser?.close();
    await server.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
