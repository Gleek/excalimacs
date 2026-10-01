import {
  CaptureUpdateAction, bumpVersion, convertToExcalidrawElements, getCommonBounds, newElementWith,
} from "@excalidraw/excalidraw";

const GEOMETRY = ["x", "y", "width", "height"];
const STYLE = ["strokeColor", "backgroundColor", "fillStyle", "strokeWidth", "strokeStyle",
  "roughness", "opacity", "link"];
const linear = (element) => element.type === "arrow" || element.type === "line";
const pick = (object, keys) => Object.fromEntries(keys.filter((key) => key in object)
  .map((key) => [key, object[key]]));

function labelOf(element, get) {
  const bound = element.boundElements?.find(({ type }) => type === "text");
  const label = bound && get(bound.id);
  return label && !label.isDeleted ? label : undefined;
}

// Text as the author wrote it, before wrapping to fit a container.
const textOf = (element, get) => {
  const source = element.type === "text" ? element : labelOf(element, get);
  return source && (source.originalText ?? source.text);
};

// A label edit bumps only the label's version, so labelled elements report both.
const versionOf = (element, get) => {
  const label = labelOf(element, get);
  return label ? `${element.version}:${label.version}` : element.version;
};

// Element states at versions agents have been shown, for field-level conflict checks.
const seen = new Map();
function remember(element, version, text) {
  const versions = seen.get(element.id) || new Map();
  versions.set(String(version), { ...element, text });
  if (versions.size > 20) versions.delete(versions.keys().next().value);
  seen.set(element.id, versions);
}

export function describe(elements, scene = elements) {
  const byId = new Map(scene.map((element) => [element.id, element]));
  return elements.filter((element) => !element.isDeleted && !element.containerId).map((element) => {
    const get = (id) => byId.get(id);
    const [text, version] = [textOf(element, get), versionOf(element, get)];
    remember(element, version, text);
    return {
      id: element.id, type: element.type, version,
      x: Math.round(element.x), y: Math.round(element.y),
      ...(linear(element)
        ? { points: element.points.map((point) => point.map(Math.round)) }
        : { width: Math.round(element.width), height: Math.round(element.height) }),
      ...(text ? { text } : {}),
      ...(element.strokeColor !== "#1e1e1e" ? { strokeColor: element.strokeColor } : {}),
      ...(element.backgroundColor !== "transparent" ? { backgroundColor: element.backgroundColor } : {}),
      ...(element.startBinding ? { from: element.startBinding.elementId } : {}),
      ...(element.endBinding ? { to: element.endBinding.elementId } : {}),
    };
  });
}

function conflict(element, scene, changed) {
  return Object.assign(new Error(`${element.id} changed since the version you read`),
    { current: describe([element], scene)[0], ...(changed ? { changed } : {}) });
}

// Throws unless FIELDS are unchanged since VERSION, so unrelated edits don't block.
function check(element, version, fields, scene) {
  const byId = new Map(scene.map((candidate) => [candidate.id, candidate]));
  const get = (id) => byId.get(id);
  if (version === undefined || String(version) === String(versionOf(element, get))) return;
  const base = seen.get(element.id)?.get(String(version));
  if (!base) throw conflict(element, scene);
  const now = { ...element, text: textOf(element, get) };
  const changed = Object.fromEntries(fields
    .filter((field) => JSON.stringify(base[field]) !== JSON.stringify(now[field]))
    .map((field) => [field, { was: base[field], now: now[field] }]));
  if (Object.keys(changed).length) throw conflict(element, scene, changed);
}

// Straight arrow geometry from the edge of one box to the edge of another.
function route(from, to) {
  const [ax, ay] = [from.x + from.width / 2, from.y + from.height / 2];
  const [dx, dy] = [to.x + to.width / 2 - ax, to.y + to.height / 2 - ay];
  const exit = (box) => Math.min(box.width / 2 / Math.abs(dx || 1e-9), box.height / 2 / Math.abs(dy || 1e-9));
  const [start, length] = [exit(from), 1 - exit(from) - exit(to)];
  return { x: ax + dx * start, y: ay + dy * start, points: [[0, 0], [dx * length, dy * length]] };
}

function prepare(skeleton, boxes) {
  if (!linear(skeleton) || skeleton.points) return skeleton;
  const [from, to] = [boxes.get(skeleton.start?.id), boxes.get(skeleton.end?.id)];
  if (skeleton.width === undefined && from?.width && to?.width) return { ...skeleton, ...route(from, to) };
  // The converter treats a zero width or height as unset; points keep it.
  return { ...skeleton, points: [[0, 0], [skeleton.width ?? 100, skeleton.height ?? 0]] };
}

function add(excalidrawAPI, skeletons, regenerateIds) {
  const scene = excalidrawAPI.getSceneElementsIncludingDeleted();
  const byId = new Map(scene.map((element) => [element.id, element]));
  const live = (id) => byId.get(id)?.isDeleted === false;
  const taken = skeletons.find((skeleton) => !regenerateIds && live(skeleton.id));
  if (taken) throw conflict(byId.get(taken.id), scene);
  const boxes = new Map([...byId, ...skeletons.filter(({ id }) => id).map((skeleton) => [skeleton.id, skeleton])]);
  const refs = new Set(skeletons.flatMap(({ start, end }) => [start?.id, end?.id])
    .filter((id) => !regenerateIds && live(id)));
  const converted = convertToExcalidrawElements(
    [...[...refs].map((id) => byId.get(id)), ...skeletons.map((skeleton) => prepare(skeleton, boxes))],
    { regenerateIds });
  const convertedById = new Map(converted.map((element) => [element.id, element]));
  // A deleted element stays as a tombstone; a reused id must outrank it when tabs merge.
  const added = converted.filter(({ id }) => !refs.has(id))
    .map((element) => byId.has(element.id) ? bumpVersion(element, byId.get(element.id).version) : element);
  const addedIds = new Set(added.map(({ id }) => id));
  excalidrawAPI.updateScene({
    elements: [...scene.filter(({ id }) => !addedIds.has(id)).map((element) => {
      if (!refs.has(element.id)) return element;
      const bound = [...(element.boundElements || []), ...(convertedById.get(element.id).boundElements || [])];
      return newElementWith(element, {
        boundElements: bound.filter((item, index) => bound.findIndex(({ id }) => id === item.id) === index),
      });
    }), ...added],
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
  return describe(added);
}

function update(excalidrawAPI, changes) {
  const scene = excalidrawAPI.getSceneElementsIncludingDeleted();
  const byId = new Map(scene.map((element) => [element.id, element]));
  for (const { id, version, ...props } of changes) {
    const element = byId.get(id);
    if (!element || element.isDeleted) throw new Error(`No element with id: ${id}`);
    check(element, version, Object.keys(props), scene);
  }
  const next = new Map();
  const added = [];
  const get = (id) => next.get(id) || byId.get(id);
  const put = (element) => next.set(element.id, element);

  for (const { id, text, ...props } of changes) {
    let element = newElementWith(get(id), { ...pick(props, GEOMETRY), ...pick(props, STYLE) });
    if (text !== undefined && element.type === "text") {
      const [measured] = convertToExcalidrawElements([{
        type: "text", x: 0, y: 0, text, fontSize: element.fontSize, fontFamily: element.fontFamily,
      }]);
      element = newElementWith(element, {
        text, originalText: text, width: measured.width, height: measured.height,
      });
    } else if (text !== undefined) {
      const old = labelOf(element, get);
      const [sized, label] = convertToExcalidrawElements(
        [{ ...element, boundElements: null, label: { text } }], { regenerateIds: false });
      if (old) put(newElementWith(old, { isDeleted: true }));
      element = newElementWith(element, {
        ...(linear(element) ? {} : { width: sized.width, height: sized.height }),
        boundElements: [...(element.boundElements || []).filter(({ id: bound }) => bound !== old?.id),
          { type: "text", id: label.id }],
      });
      added.push(label);
    }
    put(element);
  }

  const shifted = (element) => GEOMETRY.some((key) => element[key] !== byId.get(element.id)[key]);
  const reroute = (arrow) => {
    const [from, to] = [get(arrow.startBinding?.elementId), get(arrow.endBinding?.elementId)];
    if (!from || !to) return;
    const geometry = route(from, to);
    const [width, height] = geometry.points[1];
    const routed = newElementWith(arrow, { ...geometry, width: Math.abs(width), height: Math.abs(height) });
    put(routed);
    const label = labelOf(routed, get);
    if (label) {
      const [endX, endY] = arrow.points.at(-1);
      const [dx, dy] = [routed.x + width / 2 - (arrow.x + endX / 2),
        routed.y + height / 2 - (arrow.y + endY / 2)];
      put(newElementWith(label, { x: label.x + dx, y: label.y + dy }));
    }
  };
  for (const element of [...next.values()].filter((element) => !linear(element) && shifted(element))) {
    const label = labelOf(element, get);
    if (label && !added.includes(label))
      put(newElementWith(label, {
        x: element.x + (element.width - label.width) / 2,
        y: element.y + (element.height - label.height) / 2,
      }));
    for (const { id, type } of element.boundElements || [])
      if (type === "arrow" && get(id)) reroute(get(id));
  }

  excalidrawAPI.updateScene({
    elements: [...scene.map((element) => next.get(element.id) || element), ...added],
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
  return describe([...changes.map(({ id }) => get(id))], [...scene.map(({ id }) => get(id)), ...added]);
}

function remove(excalidrawAPI, payload) {
  const scene = excalidrawAPI.getSceneElementsIncludingDeleted();
  const targets = payload.split(/\s+/).filter(Boolean).map((arg) => arg.split("@"));
  for (const [id, version] of targets) {
    const element = scene.find((candidate) => candidate.id === id && !candidate.isDeleted);
    if (!element) throw new Error(`No element with id: ${id}`);
    check(element, version, ["text", ...GEOMETRY, ...STYLE], scene);
  }
  const ids = new Set(targets.map(([id]) => id));
  excalidrawAPI.updateScene({
    elements: scene.map((element) => ids.has(element.id) || ids.has(element.containerId)
      ? newElementWith(element, { isDeleted: true }) : element),
    captureUpdate: CaptureUpdateAction.IMMEDIATELY,
  });
  return { deleted: [...ids] };
}

async function mermaid(excalidrawAPI, definition) {
  const { parseMermaidToExcalidraw } = await import("@excalidraw/mermaid-to-excalidraw");
  const { elements, files } = await parseMermaidToExcalidraw(definition);
  const visible = excalidrawAPI.getSceneElements();
  const [, minY, maxX] = visible.length ? getCommonBounds(visible) : [0, 0, -100];
  if (files) excalidrawAPI.addFiles(Object.values(files));
  return add(excalidrawAPI, elements.map((element) =>
    ({ ...element, x: element.x + maxX + 100, y: element.y + minY })), true);
}

// Runs one agent operation and waits until it is saved, so the PNG matches the reply.
export async function runAgentOp(excalidrawAPI, commit, { op, payload }, present = () => {}) {
  try {
    const result = op === "scene" ? describe(excalidrawAPI.getSceneElementsIncludingDeleted())
      : op === "delete" ? remove(excalidrawAPI, payload)
      : op === "mermaid" ? await mermaid(excalidrawAPI, payload)
      : op === "update" ? update(excalidrawAPI, JSON.parse(payload))
      : add(excalidrawAPI, JSON.parse(payload), false);
    if (op !== "scene") {
      // Reply once the drawing has played, so the agent works at the speed it is drawn.
      const shown = present();
      await commit();
      await shown;
    }
    return { result };
  } catch (failure) {
    return { error: failure.message, ...pick(failure, ["changed", "current"]) };
  }
}
