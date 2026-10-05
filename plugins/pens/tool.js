import { CaptureUpdateAction, convertToExcalidrawElements, newElementWith } from "@excalidraw/excalidraw";
import { outlineElement, outlinePath, resizePen, strokeOutline } from "./strokes.js";

const svgNS = "http://www.w3.org/2000/svg";

// Host boundary: only Excalidraw's public API and a DOM container are required.
export function createPenTool(editor, container, getSettings) {
  const svg = document.createElementNS(svgNS, "svg");
  svg.classList.add("pen-preview");
  const path = document.createElementNS(svgNS, "path");
  svg.appendChild(path);
  container.appendChild(svg);
  let stroke = null;
  let holdingSpace = false;
  let previous = new Map();
  const corrected = new Map();

  const clear = () => { stroke = null; path.removeAttribute("d"); };
  const scenePoint = (event) => {
    const state = editor.getAppState();
    return [(event.clientX - state.offsetLeft) / state.zoom.value - state.scrollX,
      (event.clientY - state.offsetTop) / state.zoom.value - state.scrollY];
  };
  const render = () => {
    if (!stroke) return;
    const state = editor.getAppState();
    const rect = container.getBoundingClientRect();
    const zoom = state.zoom.value;
    stroke.outline = strokeOutline(stroke.points, stroke.preset, stroke.settings,
      stroke.pressures, stroke.simulatePressure);
    path.setAttribute("d", outlinePath(stroke.outline));
    path.setAttribute("fill", stroke.color);
    path.setAttribute("opacity", stroke.opacity / 100);
    path.setAttribute("transform", `translate(${state.offsetLeft - rect.left + state.scrollX * zoom},${state.offsetTop - rect.top + state.scrollY * zoom}) scale(${zoom})`);
    // Match Excalidraw's dark-mode color treatment.
    svg.style.filter = state.theme === "dark" ? "invert(93%) hue-rotate(180deg)" : "";
    svg.style.mixBlendMode = state.theme === "dark" ? "screen" : "multiply";
  };
  const append = (event) => {
    const samples = event.getCoalescedEvents?.();
    for (const sample of samples?.length ? samples : [event]) {
      const point = scenePoint(sample);
      const last = stroke.points.at(-1);
      if (!last || point[0] !== last[0] || point[1] !== last[1]) {
        stroke.points.push(point);
        stroke.pressures.push(stroke.settings.variability === "variable" ? sample.pressure : 1);
      }
    }
    render();
  };
  const down = (event) => {
    const state = editor.getAppState();
    const { active: preset, pens } = getSettings();
    if (state.activeTool.type !== "freedraw" || preset === "normal" || state.viewModeEnabled || holdingSpace ||
        (state.penMode && event.pointerType === "touch") ||
        !event.target.closest("canvas") ||
        event.button !== 0 || !event.isPrimary || event.ctrlKey || event.metaKey) return;
    // Keep native freehand controls visible, but own custom stroke input.
    event.preventDefault();
    event.stopPropagation();
    const settings = { ...pens[preset] };
    stroke = { pointer: event.pointerId, pointerType: event.pointerType, preset, points: [],
      settings, color: settings.color, opacity: settings.opacity, pressures: [],
      simulatePressure: settings.variability === "variable" && event.pressure === 0.5 };
    append(event);
  };
  const move = (event) => {
    if (!stroke || event.pointerId !== stroke.pointer) return;
    append(event);
  };
  const up = (event) => {
    if (!stroke || event.pointerId !== stroke.pointer) return;
    append(event);
    const [element] = convertToExcalidrawElements([outlineElement(stroke.outline, stroke)]);
    const scene = editor.getSceneElementsIncludingDeleted();
    editor.updateScene({
      elements: [element, ...scene],
      captureUpdate: CaptureUpdateAction.IMMEDIATELY,
    });
    clear();
  };
  const cancel = () => { holdingSpace = false; clear(); };
  const otherTouch = (event) => {
    if (stroke?.pointerType === "touch" && event.pointerType === "touch" &&
        event.pointerId !== stroke.pointer) clear();
  };
  const key = (event) => {
    if (event.key === "Enter" && !event.target.closest("input, textarea, select, [contenteditable=true]")) {
      const state = editor.getAppState();
      const selected = editor.getSceneElements().filter((element) => state.selectedElementIds[element.id]);
      if (selected.length === 1 && selected[0].customData?.excalimacsPen) {
        event.preventDefault(); event.stopImmediatePropagation();
      }
    }
    if (event.code === "Space" && !event.target.closest("input, textarea, [contenteditable=true]"))
      holdingSpace = true;
    if (event.key === "Escape") clear();
  };
  const keyUp = (event) => { if (event.code === "Space") holdingSpace = false; };
  const change = editor.onChange((elements, state) => {
    const colors = new Map();
    for (const element of elements) {
      if (element.type === "line" && element.polygon && element.customData?.excalimacsPen &&
          (element.backgroundColor !== element.strokeColor || element.strokeWidth !== 0 ||
            element.fillStyle !== "solid" || element.roughness !== 0 || element.roundness !== null)) {
        // Style-only mutation retains RoughJS's cached shape. Replace the element
        // so the visible fill agrees with its data, including undo and redo.
        colors.set(element.id, newElementWith(element, {
          backgroundColor: element.strokeColor, strokeWidth: 0,
          fillStyle: "solid", roughness: 0, roundness: null,
        }));
      }
    }
    if (colors.size) {
      editor.updateScene({ elements: editor.getSceneElementsIncludingDeleted()
        .map((element) => colors.get(element.id) ?? element),
      captureUpdate: CaptureUpdateAction.NEVER });
      return;
    }
    if (state.isResizing) {
      for (const element of elements) {
        const original = previous.get(element.id);
        if (!original || element.points === corrected.get(element.id) ||
            element.width === original.width && element.height === original.height) continue;
        const updates = resizePen(element, original);
        if (updates) {
          corrected.set(element.id, updates.points);
          editor.mutateElement(element, updates);
        }
      }
    } else {
      previous = new Map(elements.filter((element) => element.customData?.excalimacsPen?.points)
        .map((element) => [element.id, { ...element }]));
      corrected.clear();
    }
    // Filled pen outlines are whole strokes, not editable polyline vertices.
    if (state.selectedLinearElement && elements.some((element) =>
      element.id === state.selectedLinearElement.elementId && element.customData?.excalimacsPen)) {
      editor.updateScene({ appState: { selectedLinearElement: null },
        captureUpdate: CaptureUpdateAction.NEVER });
    }
    if (stroke && (state.activeTool.type !== "freedraw" ||
        getSettings().active !== stroke.preset)) clear();
    else render();
  });
  container.addEventListener("pointerdown", down, true);
  window.addEventListener("pointermove", move);
  window.addEventListener("pointerdown", otherTouch, true);
  window.addEventListener("pointerup", up);
  window.addEventListener("pointercancel", cancel);
  window.addEventListener("blur", cancel);
  window.addEventListener("keydown", key, true);
  window.addEventListener("keyup", keyUp);
  return () => {
    container.removeEventListener("pointerdown", down, true);
    change(); clear(); svg.remove();
    window.removeEventListener("pointermove", move);
    window.removeEventListener("pointerdown", otherTouch, true);
    window.removeEventListener("pointerup", up);
    window.removeEventListener("pointercancel", cancel);
    window.removeEventListener("blur", cancel);
    window.removeEventListener("keydown", key, true);
    window.removeEventListener("keyup", keyUp);
  };
}
