/*!
MIT License

Copyright (c) 2020 Excalidraw

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
// Adapted from zsviczian/excalidraw packages/element/src/freedrawPath.ts.
// Retrieved 2026-10-04. Removed TypeScript and host-specific easing lookup.
import { getStroke } from "perfect-freehand";

export function getFreedrawOutlinePoints(element) {
  const inputPoints = element.simulatePressure
    ? element.points
    : element.points.length
      ? element.points.map(([x, y], i) => [x, y, element.pressures[i]])
      : [[0, 0, 0.5]];
  const customOptions = element.customData?.strokeOptions?.options;
  const options = customOptions ? {
    ...customOptions,
    simulatePressure: customOptions.simulatePressure ?? element.simulatePressure,
    size: element.strokeWidth * 4.25,
    last: true,
    easing: (t) => t,
  } : {
    simulatePressure: element.simulatePressure,
    size: element.strokeWidth * 4.25,
    thinning: 0.6, smoothing: 0.5, streamline: 0.5,
    easing: (t) => Math.sin(t * Math.PI / 2),
    last: true,
  };
  return getStroke(inputPoints, options);
}
