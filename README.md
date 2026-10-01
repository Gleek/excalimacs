# Excalimacs

<img src="src/assets/excalimacs.svg" alt="Excalimacs logo" width="180">

## Excalidraw, inside your Emacs workflow

Create diagrams from your notes or code in Excalidraw, with previews in Emacs.

- Work in any major mode, including Org, Markdown, agent-shell, and code.
- Open several drawings at once, with changes saved automatically.
- Search drawing text and follow links back to your notes.
- Keep each drawing in one editable `.excalidraw.png` file.
- Draw on a phone or tablet via QR code, and manage access and logs in Emacs.

## Get started

Tested with Emacs 30. Install with Elpaca:

```elisp
(use-package excalimacs
  :ensure (:host github :repo "Gleek/excalimacs"
           :files (:defaults "dist" "bin" "skills"))
  :custom
  (excalimacs-directory "~/path/to/drawings")
  :hook ((org-mode markdown-mode prog-mode agent-shell-mode)
         . excalimacs-minor-mode))
```

The browser editor is bundled. You don't need Node.js to use the package;
Elpaca installs the `simple-httpd` dependency for you.

To create your first drawing:

1. Open a buffer and run `M-x excalimacs-create-drawing`.
2. Enter a name, or leave it blank for an automatically generated name.
3. Draw in the browser. Your changes save automatically and the preview updates in Emacs.

For a local checkout, install `simple-httpd`, add the checkout to `load-path`,
and use:

```elisp
(require 'excalimacs)
(setq excalimacs-directory "~/path/to/drawings")
(add-hook 'org-mode-hook #'excalimacs-minor-mode)
```

`excalimacs-directory` also accepts a function called without arguments in
the buffer creating the drawing. It must return a directory string; relative
paths use that buffer's `default-directory`. For example:

```elisp
(setq excalimacs-directory
      (lambda ()
        (if (derived-mode-p 'agent-shell-mode)
            ".agent-shell/diagrams/"
          "~/org-excalidraw")))
```

## Everyday usage

### Open and edit drawings

Press `RET` on a preview or click it to open the editor. You can keep several
drawings open in separate browser tabs or windows. Use `M-x excalimacs-open`
to open an existing drawing directly, including older `.excalidraw` files.

Edits save after a short pause. `Ctrl+S` or `Cmd+S` saves immediately.
A dot in the browser tab title means a save is still pending. Tabs and devices
editing the same drawing stay in sync. Edits appear in the other tabs while
you draw, and the tab you drew in saves them. Each tab merges incoming changes
with its own edits. If the file is removed, Excalimacs
stops saving and offers an unsaved copy to download.

### Open on a phone or tablet

Enable remote access in `M-x excalimacs-diagnostics` or set `excalimacs-allow-remote` to `t`, then use `C-u RET` on a drawing to choose QR code or Copy URL for a device on the same network.
QR codes require `qrencode`; keep shared URLs private because LAN HTTP is unencrypted.
The diagnostics buffer lists drawings, lets you clear access or toggle the server, and shows live logs (`excalimacs-debug` controls logging).

### Find text inside a diagram

Words written in your diagram are also stored as plain text in the buffer.
You can find them with Emacs search or tools such as ripgrep, just as you
would find text in your notes or code. Link targets are included too.

The minor mode displays an image over this text. Toggle
`M-x excalimacs-minor-mode` off to see or edit the underlying drawing block.
Searchable text is updated from the drawing when you save it.

### Copy drawings between modes

Copy a drawing from one buffer and yank it into another, for example from
an Org note into an agent-shell prompt. Excalimacs rewrites it in the
target buffer's template. The searchable text comes along when the target
keeps text, and is dropped when it doesn't, as in agent-shell. Both buffers
need `excalimacs-minor-mode` on.

### Use the PNG

`Alt+Shift+O` opens the drawing in the installed Excalidraw app on macOS,
regardless of your default image viewer. PNG drawings are opened as temporary
`.excalidraw` copies; edits in that app do not update the original PNG.

Your saved `.excalidraw.png` is already an image you can share or use in other
applications. Excalidraw generates it as part of saving, without a separate
PNG rendering tool. Keep that original file if you want to edit the drawing
again later.

### Link drawings to your notes (or anywhere)

Select an element and press `Ctrl+K` or `Cmd+K` to attach a link. Anything you
can link to in Org, you can link to from inside Excalimacs: notes, files,
headings, websites, or custom Org link types. Clicking the link opens it
through Emacs. Normal Org link confirmations still apply.

In Org buffers, these links are also included in the searchable text, so
org-roam can index links to its nodes.

### Remove a drawing

Press Delete at the start of a preview or Backspace just after it to remove
its block from the buffer. By default, Excalimacs asks whether to delete the
drawing file too.

### Draw with agents

Agents can edit a drawing while you watch and edit it too. They use the
`bin/excalimacs` command, which talks to your running Emacs, and your browser
shows each change being drawn. Install the skill that teaches an agent how to
use it, for Claude Code and Codex:

```sh
bin/excalimacs install-skill
```

For another harness, pass its skills directory:
`bin/excalimacs install-skill ~/.config/my-agent/skills`.
Then hand the agent a drawing, for example with `@file` in agent-shell.

## Use it where you work

Excalimacs is a minor mode, so it can sit alongside the major mode you already
use. It includes drawing formats for:

- **Org:** diagrams alongside your notes, with searchable text and Org links.
- **Markdown:** diagrams with their searchable text stored in an HTML comment.
- **Code:** diagrams and searchable text stored using the language's comment syntax.
- **agent-shell:** send drawings to your agents and let them draw back; see
  [Draw with agents](#draw-with-agents).
- **Anywhere else:** enable the minor mode in another major mode using a hook; see
  [Adding other modes](#adding-other-modes) below.

Other modes use a plain-text drawing block by default. You can add a custom
format through `excalimacs-templates`. The creation command also works when
the minor mode is off; enable it when you want inline previews.

## Options

Run `M-x customize-group RET excalimacs RET`, or set these in your configuration:

| Option | What it controls | Default |
| --- | --- | --- |
| `excalimacs-directory` | Where new drawings are saved | `~/org-excalidraw` |
| `excalimacs-allow-remote` | Enable remote actions by default when set to `t`; LAN listening starts when you use QR or Copy URL | `nil` |
| `excalimacs-preview-width` | Maximum preview width in pixels | `320` |
| `excalimacs-delete-file` | Whether removing a drawing also deletes its file | `ask` (`t` to delete, `nil` to keep) |
| `excalimacs-library-directory` | Where Excalidraw library files are stored | `excalimacs/` under `user-emacs-directory` |
| `excalimacs-templates` | How drawings are inserted in each major mode | Org, Markdown, code, agent-shell, and plain text |
| `excalimacs-agent-drawing-speed` | How fast agent edits are drawn, in pixels per second | `500` |
| `excalimacs-agent-typing-speed` | How fast agent text is typed, in characters per second | `20` |
| `excalimacs-agent-drawing-limit` | Longest time one agent edit takes to draw, in seconds | `8` |

### Libraries

Library items you create are saved in `library.excalidrawlib` in the library
directory. Libraries added from the Excalidraw website are saved there as
separate files. You can also copy `.excalidrawlib` files into that directory.
Refresh the editor page to pick up added, changed, or removed libraries.

### Adding other modes

Add a hook to show drawings in any other major mode:

```elisp
(add-hook 'my-mode-hook #'excalimacs-minor-mode)
```

The plain-text drawing format works by default. To give that mode its own
format, customize `excalimacs-templates` as described below.

### Custom drawing formats

For example, to add a format for another major mode:

```elisp
(add-to-list 'excalimacs-templates
             '(my-mode :begin "DRAW {file}" :end "END" :text t))
```

`:begin` must contain `{file}`. `:end` closes the block. Searchable text is
included by default; set `:text nil` for a path-only format. Use `:text-prefix`
and `:text-suffix` to wrap each text line, or `:comment t` to use the major
mode's comment syntax.

## Why I built it

I started with `org-excalidraw`, but it didn't work well for my workflow.
I [forked it](https://github.com/Gleek/org-excalidraw), made a number of fixes,
and switched PNG rendering to
[excalirender](https://github.com/Gleek/excalirender). That improved things a
lot, but two major frustrations remained:

- **Working on multiple drawings could lose work.** The Excalidraw app's shared
  browser storage made the workflow behave as if there were only one drawing.
  When I opened two files at once, one drawing could overwrite the other. I
  lost several drawings this way. This was the main reason I started Excalimacs.
- **Rendered images didn't always match Excalidraw.** The separate renderer
  wasn't always compatible with Excalidraw, leaving unexpected differences
  between the drawing in the editor and the exported PNG.

`org-draw` was another good option, but it uses tldraw. I prefer Excalidraw's
feature set, and licensing was a bigger concern: the
[tldraw SDK has its own license](https://tldraw.dev/community/license), with
license requirements for production use, while
[Excalidraw is MIT-licensed](https://github.com/excalidraw/excalidraw/blob/master/LICENSE).

Excalimacs gives each drawing its own editing session and uses Excalidraw itself
to generate the PNG. It also makes diagram text searchable in your buffers and
works as a minor mode alongside notes, code, Markdown, or agent-shell.

If you're trying it alongside `org-excalidraw`, disable that package's file
watcher and old file opener so they don't also launch the Excalidraw PWA or
invoke excalirender.

## Comparison with other packages

Comparison as of **September 30, 2026**, based on my understanding of each
package's documentation and source. “No” means no built-in integration.
This compares the original `wdavew/org-excalidraw`, not my fork.

| Feature | org-draw | Original org-excalidraw | Excalimacs |
| --- | --- | --- | --- |
| Drawing editor | tldraw | Excalidraw PWA | Bundled Excalidraw |
| Editing interface | Browser, local or remote | Installed PWA; documented for Chromium | Browser, local or remote |
| Modes supported | Org | Org | Org, Markdown, agent-shell, code, and other major modes |
| Inline previews in Org | Yes, PNG | Yes, SVG | Yes, PNG |
| Search diagram text from Emacs | No text projection | No text projection | Yes, in text-enabled templates |
| Search diagram text with ripgrep | No text projection | No text projection | Yes, in text-enabled templates |
| Follow Org links from diagram elements | No Emacs bridge | No Emacs bridge | Yes, including custom link types |
| Single editable image file | Yes, PNG with embedded tldraw snapshot | No; drawing JSON plus generated SVG | Yes, PNG with embedded Excalidraw scene |
| Preview generation | tldraw exports PNG directly | External `excalidraw_export` tool | Excalidraw exports PNG directly |
| Separate renderer required | No | Yes | No |
| Saving to Emacs | Click **Done** to submit | Save in PWA; file watcher updates SVG | Autosave, plus `Ctrl/Cmd+S` |
| Multiple drawing sessions | Session-specific URLs; receiver also supports a queue | Delegated to PWA; no package-managed isolation | Separate sessions bound to drawing files |
| Reject saves after external file changes | No file revision check found | No package-level check | Yes, file hash checks |
| Live sync between tabs and devices | No; one-shot submit on **Done** | Delegated to PWA | Yes, edits broadcast as diffs |
| Live agent editing | No it | No | Yes, through `bin/excalimacs` |
| Phone/tablet drawing over LAN | Yes | No built-in remote workflow | Yes |
| QR code opening | No built-in QR action found | No | Yes, requires `qrencode` |
| Remote access controls | Optional device pairing | Not applicable | Per-drawing access tokens and revocation |
| Server/access management UI | Setup buffer and server controls | No server | Diagnostics, access controls, live logs |
| PWA installation required | No | Yes, documented setup | No |
| External setup dependencies | No separate renderer or PWA | PWA, exporter and fonts | `simple-httpd`; optional `qrencode` |
| Emacs package license | GPL-3.0-or-later | MIT | GPLv3 |

Sources: [org-draw documentation](https://github.com/larrasket/org-draw),
[browser implementation](https://github.com/larrasket/org-draw/blob/master/web/canvas.html),
and [Emacs implementation](https://github.com/larrasket/org-draw/blob/master/org-draw.el);
[original org-excalidraw documentation](https://github.com/wdavew/org-excalidraw)
and [source](https://github.com/wdavew/org-excalidraw/blob/main/org-excalidraw.el).
Excalimacs entries describe the implementation in this repository.

### excali-mode

[excali-mode](https://github.com/yibie/excali-mode) takes a different
approach. It ports Excalidraw's editor to Emacs Lisp and a C module, and
draws on Emacs 32's new canvas API, so you edit `.excalidraw` files in an
Emacs buffer without a browser. Excalimacs keeps the browser editor and
focuses on embedding drawings in other buffers, searchable text, Org links,
remote devices and agents. The two projects started around the same time,
and I didn't know about excali-mode when I began Excalimacs. Using it as an
in-Emacs editor for Excalimacs is a possible future direction.

## Where it could go

There is room for deeper integration between Excalidraw and Emacs. Element
links and org-roam indexing already provide a starting point. Ideas I'd like
to explore include:

- An xwidget editor, so drawing and writing can happen within Emacs.
- Richer org-roam integration for creating links and navigating backlinks.
- Live cursors and presence for people and agents editing together.
- Custom Excalidraw plugins written in Elisp through the Emacs bridge.

These are possibilities, not features available today. Editing currently
happens in a browser.

## Development

The committed `dist/` is the browser app served by Excalimacs. After changing `src/` or upgrading Excalidraw, rebuild and commit the updated `dist/` with the source changes:

```sh
npm ci
npm run build
```

Run the ERT tests from the repository root, with `simple-httpd.el` on the load path:

```sh
EMACSLOADPATH=/path/to/simple-httpd: emacs -Q --batch -L . -l excalimacs.el -l tests/excalimacs-test.el -f ert-run-tests-batch-and-exit
```

Or use the npm wrapper: `EMACSLOADPATH=/path/to/simple-httpd: npm test`.

With Emacs running and Playwright Chromium installed, test CLI animations and
concurrent editing across two tabs with `npm run test:browser`.
Set `PLAYWRIGHT_MODULE` to a Playwright module path if it is installed elsewhere.
The test uses a temporary drawing and moves it to Trash afterward.

These cover stale-save rejection, Unicode request handling, and Org link creation. Full browser-to-Emacs integration has been exercised manually.

Excalimacs uses Excalidraw's `next` development release from npm, with an exact version pinned in `package.json` and `package-lock.json`. It exports the command palette directly, so no bundle patch is needed.

`next` is an npm tag, not a GitHub branch. Upstream publishes it from its
`release` branch. The version suffix identifies the source commit: for example,
`0.18.0-1118751` corresponds to commit `1118751`. To see changes since that
build, [compare it with master](https://github.com/excalidraw/excalidraw/compare/1118751...master).
Check the current npm tags with `npm view @excalidraw/excalidraw dist-tags`.

To upgrade to the latest published development build:

```sh
npm run upgrade:excalidraw
```

This installs and pins the newest `next` version and rebuilds the browser app (including fonts). It stops if a command fails; it does not roll back dependency changes. Save pending edits before upgrading, then refresh the browser afterward. No Emacs restart is needed.

Most upgrades should work without application changes, but development builds can change APIs or behavior. A passing build does not check every UI interaction: after upgrading, try editing text, saving, PNG previews, and the command palette. Upstream breaking changes may require application changes. The `next` tag points to the latest published development build; its source can differ from `master`.

## License

Excalimacs is licensed under [GPLv3](LICENSE). Excalidraw and the bundled fonts have their own licenses.
