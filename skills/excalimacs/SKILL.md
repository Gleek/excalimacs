---
name: excalimacs
description: Draw and edit Excalidraw diagrams (.excalidraw.png files) live in the user's Excalimacs editor while they watch and edit too. Use when the user shares or mentions a .excalidraw.png drawing, asks you to sketch, diagram, whiteboard or jam on one, or asks you to change an existing drawing.
---

# Drawing with Excalimacs

The `excalimacs` command edits a drawing through the user's running Emacs.
The user sees each change drawn in their browser, the way a person would
draw it, and can edit the same drawing at the same time. Run `excalimacs`
with no arguments for the full element format.
<!-- excalimacs-path -->

```sh
excalimacs scene   DRAWING           # elements as JSON, with versions
excalimacs add     DRAWING < JSON    # add element skeletons
excalimacs update  DRAWING < JSON    # move, resize, restyle, relabel
excalimacs delete  DRAWING ID[@VERSION]...
excalimacs mermaid DRAWING < MMD     # a whole Mermaid diagram at once
```

DRAWING is the file path, for example the `@file` agent-shell inserts.
If no editor tab has it open, Excalimacs opens one.

## Workflow

1. Read `scene` once before you start, and again only when a command tells
   you the drawing changed.
2. Make one change per call: one shape with its label, or one arrow. Each
   call returns after the drawing finishes, so the user can follow along.
   Batch elements only when asked to be quick, or pass `--immediate`.
3. Pass the `version` you last read to `update` and `delete`, exactly as
   given (labelled elements use strings like `"5:3"`).
4. Exit code 3 means someone else changed a property you are changing.
   Nothing was applied. The output has `changed` (`{property: {was, now}}`)
   and `current`. Combine both intents, keep their other edits, and retry
   with `current.version`. Never overwrite a person's edit blindly.
5. Look at the `.excalidraw.png` file as an image to check the result. It
   is saved before each command returns.

## Ids

Give every element you add an id with your own prefix, such as `agent-api`.
Arrows bind to elements by id, including elements added in earlier calls or
drawn by the user (find their ids with `scene`). An id you deleted may be
reused. Mermaid output gets random ids; read them back with `scene`.

## Layout

- Arrows are straight and run between the edges of the shapes they bind.
  Plan a grid so arrows go along rows or columns and don't pass through
  other shapes.
- Leave at least 150 px between shapes that an arrow with a label connects,
  so the label doesn't sit on a shape or frame.
- Keep arrow labels to one or two words. Put detail in the shape's label.
- Moving a shape with `update` re-routes its arrows, but arrows that aren't
  bound stay put. Delete and re-add those, bound, after a re-layout.
- Prefer fewer, clearer elements over covering every detail.
