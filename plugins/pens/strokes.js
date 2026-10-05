import { getFreedrawOutlinePoints } from "./vendor/outline.js";

// Both live previews and saved vectors use this exact outline.
export function strokeOutline(points, preset, settings, pressures = points.map(() => 1), simulatePressure = false) {
  const outline = getFreedrawOutlinePoints({
    points, pressures, simulatePressure,
    strokeWidth: settings.width,
    customData: { strokeOptions: { options: {
      thinning: settings.thinning, smoothing: settings.smoothing, streamline: settings.streamline,
      start: { taper: 0, cap: preset !== "highlighter", easing: (t) => t },
      end: { taper: preset === "tapered", cap: preset === "tapered", easing: (t) => t },
    } } },
  });
  // Obsidian renders quadratic curves through adjacent outline midpoints.
  // Flatten those curves for native polygons so preview and export agree.
  if (!outline.length) return outline;
  const midpoint = (a, b) => a.map((v, i) => (v + b[i]) / 2);
  const smooth = [outline[0]];
  let start = outline[0];
  for (let i = 0; i < outline.length; i++) {
    const control = outline[i];
    const end = midpoint(control, outline[(i + 1) % outline.length]);
    const steps = Math.max(2, Math.ceil(Math.hypot(end[0] - start[0], end[1] - start[1]) / 2));
    for (let step = 1; step <= steps; step++) {
      const t = step / steps;
      smooth.push(start.map((v, axis) => (1 - t) ** 2 * v +
        2 * (1 - t) * t * control[axis] + t ** 2 * end[axis]));
    }
    start = end;
  }
  return smooth;
}

export function outlinePath(points) {
  return points.length ? `M${points.map((point) => point.join(",")).join(" L")} Z` : "";
}

export function outlineElement(points, stroke) {
  const [x, y] = points[0];
  const local = points.map(([px, py]) => [px - x, py - y]);
  return {
    type: "line", polygon: true, x, y,
    width: Math.max(...points.map(([x]) => x)) - Math.min(...points.map(([x]) => x)),
    height: Math.max(...points.map(([, y]) => y)) - Math.min(...points.map(([, y]) => y)),
    points: [...local, local[0]],
    strokeColor: stroke.color, backgroundColor: stroke.color,
    strokeWidth: 0, roughness: 0, fillStyle: "solid", opacity: stroke.opacity,
    roundness: null,
    customData: { excalimacsPen: {
      preset: stroke.preset, settings: stroke.settings,
      points: stroke.points.map(([px, py]) => [px - x, py - y]),
      pressures: stroke.pressures, simulatePressure: stroke.simulatePressure,
    } },
  };
}

// Resize the centerline, then regenerate the outline at its original pen width.
export function resizePen(element, original) {
  const pen = original.customData?.excalimacsPen;
  if (!pen?.points) return null;
  const scale = [0, 1].map((axis) => {
    const index = original.points.reduce((best, point, i) =>
      Math.abs(point[axis] - original.points[0][axis]) >
      Math.abs(original.points[best][axis] - original.points[0][axis]) ? i : best, 0);
    const span = original.points[index][axis] - original.points[0][axis];
    return span ? (element.points[index][axis] - element.points[0][axis]) / span : 1;
  });
  const points = pen.points.map((point) => point.map((value, axis) =>
    element.points[0][axis] + (value - original.points[0][axis]) * scale[axis]));
  const outline = strokeOutline(points, pen.preset, pen.settings, pen.pressures, pen.simulatePressure);
  const vector = outlineElement(outline, { ...pen, points,
    color: element.backgroundColor, opacity: element.opacity });
  return { points: vector.points, x: element.x + vector.x, y: element.y + vector.y,
    width: vector.width, height: vector.height,
    customData: { ...element.customData, ...vector.customData } };
}
