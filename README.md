# Excalimacs

Excalidraw editing for Org files. New drawings are single `.excalidraw.png` files: Org displays the PNG while Excalidraw's complete editable scene is embedded in its metadata. The surrounding Org block keeps a generated plain-text projection so ordinary tools such as ripgrep can find text in a drawing. No Node server runs while editing.

## Install with Elpaca

Tested with Emacs 30. The browser app is bundled, so Node.js is not needed to use Excalimacs:

```elisp
(use-package excalimacs
  :ensure (:host github :repo "Gleek/excalimacs"
           :files (:defaults "dist"))
  :custom
  (excalimacs-directory "~/path/to/drawings")
  :hook (org-mode . excalimacs-initialize))
```

Elpaca installs the declared `simple-httpd` dependency. For a local checkout, add this directory to `load-path`, install `simple-httpd`, and configure Emacs:

```elisp
(require 'excalimacs)
(setq excalimacs-directory "~/path/to/drawings")
(add-hook 'org-mode-hook #'excalimacs-initialize)
```

In an Org buffer, run `M-x excalimacs-create-drawing`. It inserts an `excalidraw` block and opens the browser editor. The first render creates its `.excalidraw.png`; later saves atomically replace that file and update the searchable text in the Org block. If the Org buffer had no unsaved edits, Excalimacs saves the updated block to disk so ripgrep can find it immediately. Otherwise, save the Org buffer when ready. With `excalimacs-org-mode` enabled, the whole block is displayed as the PNG. Press `RET` on it to edit, or Backspace/Delete to remove the block. `excalimacs-delete-file` controls whether the PNG is also deleted: `ask` (default), `t`, or `nil`. Save the Org buffer to persist block removal. Run `M-x excalimacs-open` to edit an existing embedded PNG directly. Legacy `.excalidraw` files can still be opened.

If using `org-excalidraw`, disable its file watcher and old file opener while trying Excalimacs. They still launch the Excalidraw PWA and invoke excalirender.

## Saving

Each browser view has a separate random token bound to one file. Edits autosave after a short pause; `Cmd+S` or `Ctrl+S` saves immediately. Emacs checks the file hash before replacing it, writes a backup, and rejects stale saves. The latest 20 backups remain in `.excalidraw-backups/`.

After saving, the browser exports the same drawing revision to PNG with `exportEmbedScene` enabled and posts it to Emacs. Emacs accepts it only when the base hash matches the current file, updates matching Org blocks, and refreshes their images. The previous PNG is backed up before replacement. A dot in the browser tab title means saving is unfinished. On a conflict, the editor offers an unsaved copy for download.

The Open menu action is disabled for Emacs-hosted sessions; open another drawing from Emacs. Live collaboration is not connected.

Use **Alt+Shift+O (Option+Shift+O on macOS)** or **Open in Excalidraw app** in the menu to save pending edits and open the same file using its system file association (`open` on macOS, `xdg-open` on Linux). Associate `.excalidraw` files with the Excalidraw app first. A save failure or conflict prevents opening. After saving changes in the external app, reload the wrapper to read them; it does not automatically follow external edits.

## Development

The committed `dist/` is the browser app served by Excalimacs. After changing `src/` or upgrading Excalidraw, rebuild and commit the updated `dist/` with the source changes:

```sh
npm ci
npm run build
```

Run `npm test` for the Emacs tests, with `simple-httpd.el` on the load path: `EMACSLOADPATH=/path/to/simple-httpd: npm test`. These cover backups, stale-save rejection, Unicode request handling, and Org link creation. Full browser-to-Emacs integration has been exercised manually.

Excalidraw uses upstream's `next` development channel, with an exact version pinned in `package.json` and `package-lock.json`. It exports the command palette directly, so no bundle patch is needed.

To upgrade to the latest published development build:

```sh
npm run upgrade:excalidraw
```

This installs and pins the newest `next` version and rebuilds the browser app (including fonts). It stops if a command fails; it does not roll back dependency changes. Save pending edits before upgrading, then refresh the browser afterward. No Emacs restart is needed.

Most upgrades should work without application changes, but development builds can change APIs or behavior. A passing build does not check every UI interaction: after upgrading, try editing text, saving, PNG previews, and the command palette. Upstream breaking changes may require application changes. The `next` channel is the latest published development build, which can lag behind the head of `master`.

## License

Excalimacs is licensed under [GPLv3](LICENSE). Excalidraw and the bundled fonts have their own licenses.
