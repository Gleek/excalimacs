# Pens

Adds **Highlighter** and **Thick → thin** pens for highlighting and mind mapping.

```elisp
(setq excalimacs-plugins '(pens))
```

Reload the editor tab and select the freehand tool. Choose a pen under
**Custom pens** in the settings panel. Use the usual controls to change its
color, width, opacity, or pressure, and the gear button to adjust its stroke.
Each pen remembers its settings.

You can select, move, resize, and recolor strokes after drawing them. They
remain visible when exported or opened without the plugin.

## Credits

`vendor/outline.js` adapts `getFreedrawOutlinePoints` from
[zsviczian/excalidraw](https://github.com/zsviczian/excalidraw/blob/master/packages/element/src/freedrawPath.ts),
retrieved October 4, 2026. Its MIT copyright notice and license are retained
in the file and [vendor/LICENSE](vendor/LICENSE).

The direct `perfect-freehand` dependency is MIT licensed, copyright Stephen
Ruiz Ltd.
