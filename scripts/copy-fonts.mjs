import { cp, mkdir } from "node:fs/promises";
await mkdir(new URL("../public/", import.meta.url), { recursive: true });
await cp(new URL("../node_modules/@excalidraw/excalidraw/dist/prod/fonts/", import.meta.url),
  new URL("../public/fonts/", import.meta.url), { recursive: true, force: true });
