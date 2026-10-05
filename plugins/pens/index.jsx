import React, { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { CaptureUpdateAction, newElementWith } from "@excalidraw/excalidraw";
import { resizePen } from "./strokes.js";
import { createPenTool } from "./tool.js";
import "./style.css";

const presets = [["normal", "Normal"], ["highlighter", "Highlighter"], ["tapered", "Thick → thin"]];
const widths = { thin: 0.5, medium: 1, bold: 2 };
const widthKey = (width) => width <= 0.5 ? "thin" : width <= 1 ? "medium" : "bold";
const styleOf = (state) => ({ color: state.currentItemStrokeColor,
  width: widths[state.currentItemStrokeWidthKey] ?? 1, opacity: state.currentItemOpacity,
  variability: state.currentItemStrokeVariability });

function initialSettings(saved, state) {
  const normal = styleOf(state);
  const defaults = {
    normal,
    highlighter: { color: "#FFC47C", width: 2, opacity: 30, thinning: 1, smoothing: 0.5, streamline: 0.5 },
    // Obsidian's thick-thin preset uses grey and inherits the current pen width.
    tapered: { color: "#CECDCC", width: normal.width, opacity: normal.opacity,
      thinning: 1, smoothing: 0.5, streamline: 0.5 },
  };
  return { shapeStyle: saved?.shapeStyle ?? normal, active: presets.some(([id]) => id === saved?.active) ? saved.active : "normal",
    pens: Object.fromEntries(presets.map(([id]) => [id, { ...defaults[id], ...saved?.pens?.[id] }])) };
}

export function usePens(editor, saved, saveSettings) {
  const [settings, setSettings] = useState(null);
  const [expanded, setExpanded] = useState(false);
  const [panel, setPanel] = useState(null);
  const [visible, setVisible] = useState(false);
  const [selected, setSelected] = useState([]);
  const selectionKey = useRef("");
  const current = useRef(null);
  const appliedStyle = useRef(null);

  const remember = (next) => {
    current.current = next;
    setSettings(next);
    saveSettings(next);
  };
  const applyStyle = (style) => {
    appliedStyle.current = { color: style.color, width: widths[widthKey(style.width)], opacity: style.opacity,
      variability: style.variability ?? "constant" };
    editor.updateScene({ appState: {
      currentItemStrokeColor: style.color, currentItemStrokeWidthKey: widthKey(style.width),
      currentItemOpacity: style.opacity,
      currentItemStrokeVariability: appliedStyle.current.variability,
    }, captureUpdate: CaptureUpdateAction.NEVER });
  };
  const apply = (next) => {
    applyStyle(next.pens[next.active]);
    editor.setActiveTool({ type: "freedraw" });
  };
  const update = (next) => { remember(next); apply(next); };

  useEffect(() => {
    if (!editor) return;
    const next = initialSettings(saved, editor.getAppState());
    current.current = next;
    setSettings(next);
    setSelected([]);
    selectionKey.current = "";
    let drawingPen = false;
    const container = document.querySelector(".app > .excalidraw");
    const dispose = createPenTool(editor, container, () => current.current);
    // No upstream panel extension slot: isolate the DOM attachment here.
    const locatePanel = () => setPanel([...container.querySelectorAll(
      ".selected-shape-actions-container div.selected-shape-actions, .selected-shape-actions-container .compact-shape-actions, .mobile-shape-actions")]
      .find((element) => element.offsetParent !== null) ?? null);
    const observer = new MutationObserver(locatePanel);
    observer.observe(container, { childList: true, subtree: true });
    window.addEventListener("resize", locatePanel);
    locatePanel();
    setVisible(editor.getAppState().activeTool.type === "freedraw");
    const unsubscribe = editor.onChange((elements, state) => {
      const selection = elements.filter((element) => state.selectedElementIds[element.id]);
      const onlyPens = selection.length > 0 && selection.every((element) =>
        element.type === "line" && element.polygon && element.customData?.excalimacsPen);
      container.classList.toggle("pen-selection", onlyPens);
      const key = onlyPens ? selection.map(({ id, version }) => `${id}:${version}`).join(",") : "";
      if (key !== selectionKey.current) {
        selectionKey.current = key;
        setSelected(onlyPens ? selection : []);
      }
      if (state.isLoading) return;
      const { active, pens } = current.current;
      const tool = state.activeTool;
      setVisible(tool.type === "freedraw" && !state.viewModeEnabled && !state.zenModeEnabled);
      if (tool.type !== "freedraw") {
        if (drawingPen) {
          drawingPen = false;
          applyStyle(current.current.shapeStyle);
        } else if (!selection.length) {
          const shapeStyle = styleOf(state);
          if (Object.keys(shapeStyle).some((key) => shapeStyle[key] !== current.current.shapeStyle[key]))
            remember({ ...current.current, shapeStyle });
        }
        return;
      }
      if (!drawingPen) { drawingPen = true; apply(current.current); return; }
      const style = styleOf(state);
      const changes = Object.fromEntries(Object.entries(style)
        .filter(([key, value]) => value !== appliedStyle.current?.[key]));
      if (!Object.keys(changes).length) return;
      appliedStyle.current = style;
      remember({ ...current.current, pens: { ...pens, [active]: { ...pens[active], ...changes } } });
    });
    return () => { dispose(); unsubscribe(); observer.disconnect(); container.classList.remove("pen-selection"); window.removeEventListener("resize", locatePanel); };
  }, [editor]);

  const choose = (active) => update({ ...current.current, active });
  const change = (key, value) => {
    const { active, pens } = current.current;
    update({ ...current.current, pens: { ...pens, [active]: { ...pens[active], [key]: value } } });
  };
  if (!editor || !settings || !panel || (!visible && !selected.length)) return null;
  if (selected.length) {
    if (!selected.every((element) => element.customData.excalimacsPen.settings)) return null;
    const values = selected.map((element) => element.customData.excalimacsPen.settings.width);
    const width = values.every((value) => value === values[0]) ? values[0] : "";
    const editWidth = (value) => editor.updateScene({
      elements: editor.getSceneElementsIncludingDeleted().map((element) => {
        if (!selected.some(({ id }) => id === element.id)) return element;
        const pen = element.customData.excalimacsPen;
        const original = { ...element, customData: { ...element.customData,
          excalimacsPen: { ...pen, settings: { ...pen.settings, width: value } } } };
        return newElementWith(element, resizePen(element, original));
      }),
      captureUpdate: CaptureUpdateAction.IMMEDIATELY,
    });
    return createPortal(<fieldset className="pen-selection-settings">
      <legend>Stroke width</legend>
      <div className="buttonList" role="radiogroup" aria-label="Pen stroke width">
        {Object.entries(widths).map(([key, value], index) => {
          const title = key[0].toUpperCase() + key.slice(1);
          return <label key={key} title={title} className={width === value ? "active" : ""}>
            <input type="radio" name="pen-stroke-width" aria-label={title}
              checked={width === value} onChange={() => editWidth(value)} />
            <svg viewBox="0 0 20 20" width="20" height="20" fill="none" aria-hidden="true">
              <path d={index === 0 ? "M4.167 10h11.666" : "M5 10h10"}
                stroke="currentColor" strokeWidth={(index + 1) * 1.25}
                strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </label>;
        })}
      </div>
    </fieldset>, panel);
  }
  const style = settings.pens[settings.active];
  return createPortal(<fieldset className="pens-plugin">
    <legend>Custom pens</legend>
    <div className="pens-toolbar" role="toolbar" aria-label="Pens">
      {presets.map(([id, label]) => <button key={id} type="button"
        aria-pressed={settings.active === id} onClick={() => choose(id)} title={label}>{label}</button>)}
      {settings.active !== "normal" && <button type="button" aria-label="Pen settings" aria-expanded={expanded}
        onClick={() => setExpanded(!expanded)}>⚙</button>}
    </div>
    {expanded && settings.active !== "normal" && <div className="pen-settings" role="group" aria-label="Pen settings">
      {["thinning", "smoothing", "streamline"].map((key) =>
        <label key={key}>{key} <input aria-label={`Pen ${key}`} type="range" min="0" max="1" step="0.05"
          value={style[key]} onChange={(event) => change(key, Number(event.target.value))} /></label>)}
    </div>}
  </fieldset>, panel);
}
