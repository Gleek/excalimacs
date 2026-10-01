import { exportToSvg, getCommonBounds } from "@excalidraw/excalidraw";

const PADDING = 10;
// Pause between elements, like lifting the pen.
const PAUSE = 150;
const clamp = (value) => Math.max(0, Math.min(1, value));
// Fast start and a gentle arrival, like a hand dragging to a target.
const ease = (value) => 1 - (1 - clamp(value)) ** 2;
const lerp = (from, to, t) => from + (to - from) * t;
const linear = (element) => ["arrow", "line", "freedraw"].includes(element.type);
const characters = (element) => Array.from(element.text || "");

const pathLength = (points) => points.slice(1).reduce((sum, [x, y], index) =>
  sum + Math.hypot(x - points[index][0], y - points[index][1]), 0);

// The part of a polyline drawn after fraction T of its length.
function prefix(points, t) {
  let remaining = pathLength(points) * t;
  const drawn = [points[0]];
  for (let index = 1; index < points.length; index++) {
    const [[ax, ay], [bx, by]] = [points[index - 1], points[index]];
    const step = Math.hypot(bx - ax, by - ay);
    if (step >= remaining) {
      const fraction = step ? remaining / step : 1;
      drawn.push([lerp(ax, bx, fraction), lerp(ay, by, fraction)]);
      return drawn;
    }
    drawn.push(points[index]);
    remaining -= step;
  }
  return drawn;
}

const sizeOf = (points) => ({
  width: Math.max(...points.map(([x]) => x)) - Math.min(...points.map(([x]) => x)),
  height: Math.max(...points.map(([, y]) => y)) - Math.min(...points.map(([, y]) => y)),
});

// The root element after fraction T of being drawn, or of moving from FROM.
function shapeAt(root, from, t) {
  if (linear(root)) {
    const morph = from?.points?.length === root.points.length;
    const points = morph
      ? root.points.map(([x, y], index) => [lerp(from.points[index][0], x, t), lerp(from.points[index][1], y, t)])
      : prefix(root.points, t);
    return {
      ...root, points, ...sizeOf(points),
      ...(morph ? { x: lerp(from.x, root.x, t), y: lerp(from.y, root.y, t) } : {}),
      ...(root.type === "freedraw" ? { pressures: root.pressures.slice(0, points.length) } : {}),
    };
  }
  // New shapes grow from their top-left corner, as if dragged diagonally.
  const start = from || { x: root.x, y: root.y, width: 0, height: 0 };
  return {
    ...root,
    x: lerp(start.x, root.x, t), y: lerp(start.y, root.y, t),
    width: Math.max(1, lerp(start.width, root.width, t)),
    height: Math.max(1, lerp(start.height, root.height, t)),
  };
}

function shapeDistance(root, from) {
  if (root.type === "text" || root.containerId) return 0;
  if (linear(root)) return from?.points?.length === root.points.length
    ? Math.max(...root.points.map(([x, y], index) =>
      Math.hypot(x + root.x - from.points[index][0] - from.x, y + root.y - from.points[index][1] - from.y)))
    : pathLength(root.points);
  return from
    ? Math.hypot(root.x - from.x, root.y - from.y) + Math.hypot(root.width - from.width, root.height - from.height)
    : Math.hypot(root.width, root.height);
}

// These SVG frames and opacity overrides never enter the scene, undo history or exports.
export function createAgentAnimator(api, container) {
  const layer = document.createElement("div");
  layer.className = "agent-animation-layer";
  container.appendChild(layer);
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  let groups = [], frame, hidden = new Set();

  const finish = (group) => {
    group.node?.remove();
    group.done();
  };
  const retain = (predicate) => {
    groups = groups.filter((group) => predicate(group) || (finish(group), false));
  };
  const clear = () => {
    cancelAnimationFrame(frame);
    retain(() => false);
    hidden.clear();
    api.setElementRenderOverrides(null);
  };
  const motionChanged = () => { if (reducedMotion.matches) clear(); };
  reducedMotion.addEventListener("change", motionChanged);

  // Elements for the frame at NOW: the shape so far, then its labels being typed.
  function frameAt(group, now) {
    const elapsed = now - group.start;
    const t = group.shapeDuration ? ease(elapsed / group.shapeDuration) : 1;
    const typed = Math.ceil(group.characters *
      (group.textDuration ? clamp((elapsed - group.shapeDuration) / group.textDuration) : 1));
    let budget = typed;
    const type = (element) => {
      const shown = characters(element).slice(0, Math.max(0, budget)).join("");
      budget -= characters(element).length;
      return shown;
    };
    const root = shapeAt(group.root, group.from, t);
    const [dx, dy] = [root.x + root.width / 2 - (group.root.x + group.root.width / 2),
      root.y + root.height / 2 - (group.root.y + group.root.height / 2)];
    const labels = group.labels.map((label) => ({
      ...label, x: label.x + dx, y: label.y + dy,
      ...(group.typing.has(label.id) ? { text: t < 1 ? "" : type(label) } : {}),
    })).filter(({ text }) => text);
    return {
      key: `${t.toFixed(3)}:${typed}`,
      elements: [{ ...root, containerId: null, ...(group.typesRoot ? { text: type(group.root) } : {}) }, ...labels],
    };
  }

  async function render(group, now) {
    if (group.rendering) return;
    const { key, elements } = frameAt(group, now);
    if (key === group.key) return;
    group.rendering = true;
    try {
      const state = api.getAppState();
      const svg = await exportToSvg({
        elements, files: api.getFiles(),
        // exportScale defaults to devicePixelRatio; the layer applies zoom itself.
        appState: { ...state, exportScale: 1, exportBackground: false, exportEmbedScene: false,
          exportWithDarkMode: state.theme === "dark" },
        exportPadding: PADDING, skipInliningFonts: true,
      });
      if (!groups.includes(group)) return;
      group.node ||= layer.appendChild(Object.assign(document.createElement("div"), {
        className: "agent-animation-element",
      }));
      group.node.dataset.elementId = group.root.id;
      group.node.replaceChildren(svg);
      const [minX, minY] = getCommonBounds(elements);
      group.origin = { x: minX - PADDING, y: minY - PADDING };
      group.key = key;
      place(group);
    } finally {
      group.rendering = false;
    }
  }

  function place(group) {
    if (!group.node) return;
    const state = api.getAppState();
    const rect = container.getBoundingClientRect();
    const zoom = state.zoom.value;
    group.node.style.transform = `translate(${state.offsetLeft - rect.left + (group.origin.x + state.scrollX) * zoom}px, ${state.offsetTop - rect.top + (group.origin.y + state.scrollY) * zoom}px) scale(${zoom})`;
  }

  const tick = (now) => {
    retain((group) => now < group.end);
    for (const group of groups.filter((candidate) => now >= candidate.start)) {
      void render(group, now).catch((error) => {
        retain((candidate) => candidate !== group);
        console.warn("Agent animation skipped", error);
      });
      place(group);
    }
    const next = new Set(groups.flatMap((group) => [group.root.id, ...group.labels.map(({ id }) => id)]));
    if (hidden.size !== next.size || [...hidden].some((id) => !next.has(id))) {
      api.setElementRenderOverrides(next.size ? new Map([...next].map((id) => [id, { opacity: 0 }])) : null);
      hidden = next;
    }
    if (groups.length) frame = requestAnimationFrame(tick);
  };

  return {
    clear,
    dispose() {
      clear();
      reducedMotion.removeEventListener("change", motionChanged);
      layer.remove();
    },
    // Draws ELEMENTS one after another; PREVIOUS maps ids to their state before the edit.
    // Resolves when the drawing is finished or interrupted.
    play(elements, previous = new Map(), settings) {
      if (!settings || document.hidden || reducedMotion.matches) return Promise.resolve();
      const scene = api.getSceneElements();
      const ids = new Set(elements.map(({ id }) => id));
      retain((group) => ![group.root, ...group.labels].some(({ id }) => ids.has(id)));
      const roots = elements.filter((element) => !element.isDeleted &&
        (!element.containerId || !ids.has(element.containerId)));
      const changedText = (element) => previous.get(element.id)?.text !== element.text;
      const planned = roots.map((root) => {
        const labels = root.containerId ? [] : scene.filter(({ containerId }) => containerId === root.id);
        const typing = new Set(labels.filter(changedText).map(({ id }) => id));
        const typesRoot = (root.type === "text" || !!root.containerId) && changedText(root);
        const typed = [...(typesRoot ? [root] : []), ...labels.filter(({ id }) => typing.has(id))];
        return {
          root, labels, typing, typesRoot, from: previous.get(root.id),
          characters: typed.reduce((sum, element) => sum + characters(element).length, 0),
          shapeDuration: shapeDistance(root, previous.get(root.id)) / settings.pixelsPerSecond * 1000,
        };
      }).map((group) => ({ ...group, textDuration: group.characters / settings.charactersPerSecond * 1000 }));
      // Adjustments move together, as when dragging a shape drags its arrows;
      // new elements are drawn one after another.
      const length = (group) => group.shapeDuration + group.textDuration + PAUSE;
      const adjusted = planned.filter((group) => group.from);
      const drawn = planned.filter((group) => !group.from);
      const total = Math.max(0, ...adjusted.map(length)) + drawn.reduce((sum, group) => sum + length(group), 0);
      // Long operations are drawn faster so one call never exceeds the limit.
      const scale = Math.min(1, settings.limit * 1000 / (total || 1));
      let start = Math.max(performance.now(), ...groups.map((group) => group.end));
      const schedule = (group, at) => new Promise((done) => {
        group.shapeDuration *= scale;
        group.textDuration *= scale;
        Object.assign(group, { start: at, end: at + group.shapeDuration + group.textDuration + PAUSE * scale, done });
        groups.push(group);
      });
      const finished = adjusted.map((group) => schedule(group, start));
      start = Math.max(start, ...adjusted.map((group) => group.end));
      for (const group of drawn) {
        finished.push(schedule(group, start));
        start = group.end;
      }
      cancelAnimationFrame(frame);
      tick(performance.now());
      return Promise.all(finished);
    },
    observe(elements) {
      const byId = new Map(elements.map((element) => [element.id, element]));
      retain((group) => [group.root, ...group.labels].every((element) =>
        byId.get(element.id)?.version === element.version && !byId.get(element.id)?.isDeleted));
    },
  };
}
