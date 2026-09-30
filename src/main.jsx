import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  CommandPalette, Excalidraw, MainMenu, WelcomeScreen, exportToBlob,
  loadSceneOrLibraryFromBlob, serializeAsJSON, serializeLibraryAsJSON,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./style.css";
import logo from "./assets/excalimacs.svg";

window.EXCALIDRAW_ASSET_PATH = "/";
const hashParams = new URLSearchParams(location.hash.slice(1));
const queryParams = new URLSearchParams(location.search);
const libraryToken = queryParams.get("libraryToken");
let token = queryParams.get("token");
if (!token && libraryToken) token = localStorage.getItem(`excalimacs-return:${libraryToken}`);
if (token && !queryParams.has("token")) {
  queryParams.set("token", token);
  history.replaceState(null, "", `${location.pathname}?${queryParams}${location.hash}`);
}

async function api(method, payload, path = "/api/drawing") {
  const response = await fetch(path, {
    method,
    headers: {
      ...(token ? { "X-Editor-Token": token } : {}),
      ...(libraryToken && method === "POST" && path === "/api/library"
        ? { "X-Library-Token": libraryToken } : {}),
      ...(payload ? { "Content-Type": "application/json" } : {}),
    },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const result = await response.json();
  if (!response.ok) {
    const error = new Error(result.error || `HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return result;
}

const libraryUrl = hashParams.get("addLibrary");
const libraryImport = libraryUrl ? api("POST", { url: libraryUrl }, "/api/library").then(() => {
  hashParams.delete("addLibrary");
  hashParams.delete("token");
  history.replaceState(null, "", `${location.pathname}${location.search}${hashParams.size ? `#${hashParams}` : ""}`);
  return true;
}) : Promise.resolve(false);

async function loadDrawing() {
  const response = await fetch("/api/drawing", {
    headers: { "X-Editor-Token": token },
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  if (response.headers.get("content-type")?.startsWith("image/png")) {
    const loaded = await loadSceneOrLibraryFromBlob(await response.blob(), null, null);
    return {
      drawing: loaded.data,
      hash: response.headers.get("x-drawing-hash"),
      name: response.headers.get("x-drawing-name") || "drawing.excalidraw.png",
      format: "png",
    };
  }
  return response.json();
}

function searchableText(text) {
  const seen = new Set();
  return JSON.parse(text).elements
    .filter((element) => !element.isDeleted)
    .flatMap((element) => [
      ...(element.type === "text" && element.text ? element.text.split("\n") : []),
      ...(element.link ? [element.link.trim().startsWith("[[")
        ? element.link.trim()
        : `[[${element.link.trim().replace(/(\\*)($|[\[\]])/g, (_, slashes, bracket) =>
          slashes + slashes + (bracket ? `\\${bracket}` : ""))}]]`] : []),
    ])
    .map((line) => line.trim())
    .filter((line) => line && !seen.has(line) && seen.add(line))
    .map((line) => `: ${line}`);
}

function App() {
  const importOnly = !token && !!libraryToken && !!libraryUrl;
  const [document, setDocument] = useState(null);
  const [importResult, setImportResult] = useState("Importing library…");
  const [libraryReturnUrl, setLibraryReturnUrl] = useState(null);
  const [status, setStatus] = useState("Loading…");
  const [conflict, setConflict] = useState(false);
  const [error, setError] = useState("");
  const [previewError, setPreviewError] = useState("");
  const [libraryError, setLibraryError] = useState("");
  const [importError, setImportError] = useState("");
  const [libraryItems, setLibraryItems] = useState(null);
  const [excalidrawAPI, setExcalidrawAPI] = useState(null);
  const [themePreference, setThemePreference] = useState("system");
  const [systemDark, setSystemDark] = useState(() => matchMedia("(prefers-color-scheme: dark)").matches);
  const hashRef = useRef(null);
  const savedRef = useRef(null);
  const currentRef = useRef(null);
  const timerRef = useRef(null);
  const savingRef = useRef(null);
  const saveRef = useRef(null);
  const conflictRef = useRef(false);
  const previewPendingRef = useRef(0);
  const libraryHashRef = useRef(null);
  const libraryTextRef = useRef(null);
  const librarySaveRef = useRef(Promise.resolve());
  const importedLibraryRef = useRef(false);

  useEffect(() => {
    if (!token) return;
    api("GET", null, "/api/library-token")
      .then(({ token: scoped }) => {
        localStorage.setItem(`excalimacs-return:${scoped}`, token);
        setLibraryReturnUrl(`${location.origin}${location.pathname}?libraryToken=${scoped}`);
      }).catch((failure) => setLibraryError(`Library link could not be prepared: ${failure.message}`));
  }, []);

  const refreshLibrary = useCallback(async () => {
    const { library, hash } = await api("GET", null, "/api/library");
    const text = serializeLibraryAsJSON(library.libraryItems);
    libraryHashRef.current = hash;
    if (text === libraryTextRef.current) return;
    libraryTextRef.current = text;
    setLibraryItems(library.libraryItems);
    await excalidrawAPI?.updateLibrary({ libraryItems: library.libraryItems, merge: false });
  }, [excalidrawAPI]);

  useEffect(() => {
    if (importOnly) {
      libraryImport.then(() => setImportResult("Library added. Return to your Excalimacs editor."))
        .catch((failure) => setImportResult(`Library import failed: ${failure.message}`));
      return;
    }
    loadDrawing().then(({ drawing, hash, name, format }) => {
      hashRef.current = hash;
      savedRef.current = serializeAsJSON(drawing.elements, drawing.appState, drawing.files, "local");
      currentRef.current = savedRef.current;
      setDocument({ drawing, name, format });
      setStatus("Saved");
    }).catch((failure) => setError(failure.message));
  }, []);

  useEffect(() => {
    if (importOnly) return;
    libraryImport.catch((failure) => {
      setImportError(`Library could not be imported: ${failure.message}`);
    }).then(() => refreshLibrary()).catch((failure) => {
      setLibraryError(`Library could not be loaded: ${failure.message}`);
      setLibraryItems([]);
    });
  }, []);

  useEffect(() => {
    if (!excalidrawAPI || !libraryItems || importedLibraryRef.current) return;
    libraryImport.then((imported) => {
      if (imported) {
        importedLibraryRef.current = true;
        excalidrawAPI.updateLibrary({ libraryItems, merge: false, openLibraryMenu: true });
      }
    }).catch(() => {});
  }, [excalidrawAPI, libraryItems]);

  useEffect(() => {
    if (!excalidrawAPI) return;
    const timer = setInterval(() => refreshLibrary().catch((failure) =>
      setLibraryError(`Library could not be loaded: ${failure.message}`)), 2000);
    return () => clearInterval(timer);
  }, [excalidrawAPI, refreshLibrary]);

  const libraryChanged = useCallback((items) => {
    const text = serializeLibraryAsJSON(items);
    if (text === libraryTextRef.current) return Promise.resolve();
    const pending = librarySaveRef.current.then(async () => {
      const result = await api("PUT", { baseHash: libraryHashRef.current, text }, "/api/library");
      libraryHashRef.current = result.hash;
      libraryTextRef.current = text;
      setLibraryError("");
    }).catch((failure) => {
      setLibraryError(`Library could not be saved: ${failure.message}. Export it from the library menu before closing.`);
      throw failure;
    });
    librarySaveRef.current = pending.catch(() => {});
    return pending;
  }, []);

  const renderPreview = useCallback(async (text, hash) => {
    previewPendingRef.current += 1;
    const canonical = document?.format === "png";
    try {
      const drawing = JSON.parse(text);
      const png = await exportToBlob({
        elements: drawing.elements,
        appState: {
          ...drawing.appState, exportBackground: true,
          exportWithDarkMode: false, exportEmbedScene: document?.format === "png",
        },
        files: drawing.files,
        mimeType: "image/png",
      });
      const headers = {
        "X-Editor-Token": token,
        "Content-Type": "image/png",
        ...(canonical && hash ? { "X-Base-Hash": hash } : {}),
        ...(!canonical ? { "X-Drawing-Hash": hash } : {}),
      };
      const response = await fetch(canonical ? "/api/drawing" : "/api/preview", {
        method: canonical ? "PUT" : "POST",
        headers,
        body: png,
      });
      const result = await response.json();
      if (!response.ok) {
        const failure = new Error(result.error || `HTTP ${response.status}`);
        failure.status = response.status;
        throw failure;
      }
      if (canonical) return result.hash;
      if (hashRef.current === hash) {
        setPreviewError("");
        setStatus(currentRef.current === savedRef.current ? "Saved" : "Unsaved changes");
      }
    } catch (failure) {
      if (canonical) throw failure;
      if (hashRef.current === hash && failure.status !== 409) {
        setPreviewError(failure.message);
        setStatus("Preview failed");
      }
    } finally {
      previewPendingRef.current -= 1;
    }
  }, [document?.format]);

  useEffect(() => {
    if (!document) return;
    if (document.format === "png" && hashRef.current) return;
    setStatus("Preview updating…");
    const pending = window.document.fonts.ready.then(async () => {
      const text = savedRef.current;
      const hash = await renderPreview(text, hashRef.current);
      if (document.format === "png") {
        hashRef.current = hash;
        await api("POST", { hash, lines: searchableText(text) }, "/api/text");
        setStatus(currentRef.current === text ? "Saved" : "Unsaved changes");
      }
    });
    if (document.format === "png") savingRef.current = pending;
    void pending.then(() => {
      if (savingRef.current === pending) savingRef.current = null;
      if (!conflictRef.current && currentRef.current !== savedRef.current)
        timerRef.current = setTimeout(() => saveRef.current(), 1200);
    }).catch((failure) => {
      if (savingRef.current === pending) savingRef.current = null;
      if (failure.status === 409) {
        conflictRef.current = true;
        setConflict(true);
      } else setError(failure.message);
      setStatus("Save failed");
    });
  }, [document, renderPreview]);

  useEffect(() => {
    const media = matchMedia("(prefers-color-scheme: dark)");
    const update = () => setSystemDark(media.matches);
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, []);

  const save = useCallback(() => {
    clearTimeout(timerRef.current);
    if (savingRef.current) return savingRef.current;
    if (conflictRef.current || !currentRef.current || currentRef.current === savedRef.current)
      return Promise.resolve();
    const text = currentRef.current;
    setStatus("Saving…");
    const pending = (async () => {
      try {
        const result = document?.format === "png"
          ? { hash: await window.document.fonts.ready.then(() => renderPreview(text, hashRef.current)) }
          : await api("PUT", { baseHash: hashRef.current, text });
        hashRef.current = result.hash;
        savedRef.current = text;
        setError("");
        setStatus(currentRef.current === text ? "Saved" : "Unsaved changes");
        if (document?.format === "png") {
          try {
            await api("POST", { hash: result.hash, lines: searchableText(text) }, "/api/text");
            setPreviewError("");
          } catch (failure) {
            setPreviewError(`Search text could not be updated: ${failure.message}`);
          }
        } else void renderPreview(text, result.hash);
      } catch (failure) {
        if (failure.status === 409) {
          conflictRef.current = true;
          setConflict(true);
          setStatus("Save blocked: file changed on disk");
        } else {
          setStatus("Save failed");
          setError(failure.message);
        }
      } finally {
        savingRef.current = null;
        if (!conflictRef.current && currentRef.current !== savedRef.current)
          timerRef.current = setTimeout(save, 1200);
      }
    })();
    savingRef.current = pending;
    return pending;
  }, [renderPreview, document?.format]);
  saveRef.current = save;

  const changed = useCallback((elements, appState, files) => {
    currentRef.current = serializeAsJSON(elements, appState, files, "local");
    if (currentRef.current === savedRef.current || conflictRef.current) return;
    setStatus("Unsaved changes");
    clearTimeout(timerRef.current);
    timerRef.current = setTimeout(save, 1200);
  }, [save]);

  const openInApp = useCallback(async () => {
    try {
      await save();
      if (conflictRef.current || currentRef.current !== savedRef.current) return;
      await api("POST", { text: savedRef.current }, "/api/open-in-app");
    } catch (failure) {
      setError(failure.message);
    }
  }, [save]);

  const openLink = useCallback((element, event) => {
    event.preventDefault();
    if (!element.link) return;
    void api("POST", { link: element.link }, "/api/open-link")
      .catch((failure) => setError(`Could not open link: ${failure.message}`));
  }, []);

  useEffect(() => {
    const keydown = (event) => {
      if (event.altKey && event.shiftKey && event.code === "KeyO") {
        event.preventDefault();
        event.stopPropagation();
        void openInApp();
        return;
      }
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        void save();
      }
    };
    const beforeUnload = (event) => {
      if (currentRef.current !== savedRef.current || previewPendingRef.current > 0) {
        event.preventDefault();
        event.returnValue = "";
      }
    };
    window.addEventListener("keydown", keydown, true);
    window.addEventListener("beforeunload", beforeUnload);
    return () => {
      window.removeEventListener("keydown", keydown, true);
      window.removeEventListener("beforeunload", beforeUnload);
    };
  }, [save, openInApp]);

  const download = async (unsaved = false) => {
    const drawing = JSON.parse(currentRef.current);
    const blob = document.format === "png"
      ? await exportToBlob({
          elements: drawing.elements,
          appState: { ...drawing.appState, exportEmbedScene: true, exportBackground: true },
          files: drawing.files,
          mimeType: "image/png",
        })
      : new Blob([currentRef.current], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const link = window.document.createElement("a");
    link.href = url;
    const name = document.name.split("/").at(-1);
    link.download = unsaved
      ? (document.format === "png"
          ? name.replace(/\.excalidraw\.png$/, ".unsaved.excalidraw.png")
          : `${name}.unsaved.excalidraw`)
      : name;
    link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  };

  if (importOnly) return <main className="message">{importResult}</main>;
  if (error && !document) return <main className="message">Could not open drawing: {error}</main>;
  if (!document || !libraryItems || !libraryReturnUrl)
    return <main className="message">Loading drawing and library…{libraryError}{importError}</main>;
  window.document.title = `${status === "Saved" ? "" : "● "}${document.name.split("/").at(-1)}`;
  const theme = themePreference === "system" ? (systemDark ? "dark" : "light") : themePreference;

  return <div className="app">
    {(conflict || error) && <aside role="alert">
      {conflict ? "The file changed outside this editor. Your edits remain here; download a copy before closing." : error}
      <button onClick={() => void download(true)}>Download unsaved copy</button>
    </aside>}
    {previewError && <aside role="alert">Drawing saved, but preview failed: {previewError}
      <button onClick={() => void renderPreview(savedRef.current, hashRef.current)}>Retry preview</button>
    </aside>}
    {libraryError && <aside role="alert">{libraryError}</aside>}
    {importError && <aside role="alert">{importError}</aside>}
    <Excalidraw excalidrawAPI={setExcalidrawAPI} libraryReturnUrl={libraryReturnUrl}
      handleKeyboardGlobally
      initialData={{ ...document.drawing, libraryItems }}
      onLibraryChange={libraryChanged} onChange={changed} onLinkOpen={openLink} theme={theme}
      onThemeChange={setThemePreference}
      UIOptions={{ canvasActions: { toggleTheme: true } }}>
      <MainMenu>
        <MainMenu.Item disabled>Open… (use Emacs)</MainMenu.Item>
        <MainMenu.Item onSelect={() => void openInApp()}>Open in Excalidraw app (Alt+Shift+O)</MainMenu.Item>
        <MainMenu.Item onSelect={() => void download()}>Save to…</MainMenu.Item>
        <MainMenu.DefaultItems.SaveAsImage />
        <MainMenu.Separator />
        <MainMenu.DefaultItems.CommandPalette />
        <MainMenu.DefaultItems.SearchMenu />
        <MainMenu.DefaultItems.Help />
        <MainMenu.DefaultItems.ClearCanvas />
        <MainMenu.Separator />
        <MainMenu.DefaultItems.ToggleTheme allowSystemTheme theme={themePreference} />
        <MainMenu.DefaultItems.ChangeCanvasBackground />
      </MainMenu>
      <CommandPalette />
      <WelcomeScreen>
        <WelcomeScreen.Center>
          <WelcomeScreen.Center.Logo>
            <img className="welcome-logo" src={logo} alt="" />
          </WelcomeScreen.Center.Logo>
          <WelcomeScreen.Center.Heading>Excalimacs</WelcomeScreen.Center.Heading>
        </WelcomeScreen.Center>
      </WelcomeScreen>
    </Excalidraw>
  </div>;
}

createRoot(window.document.getElementById("root")).render(<App />);
