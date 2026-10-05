import test from "node:test";
import assert from "node:assert/strict";
import { linkTarget, selectionLink } from "../src/drawing-links.js";

const elements = [
  { id: "a", groupIds: ["g", "parent"], x: 100 },
  { id: "b", groupIds: ["g"] },
  { id: "deleted", groupIds: ["g"], isDeleted: true },
  { id: "other", groupIds: [] },
];

test("selection links resolve current elements and nested groups", () => {
  const link = "excalimacs:%2Ftmp%2Fdrawing.excalidraw.png";
  assert.equal(selectionLink(link, "a", "element"), `${link}#element=a`);
  assert.deepEqual(linkTarget(elements, "#element=a"), [elements[0]]);
  assert.deepEqual(linkTarget(elements, "#group=g"), elements.slice(0, 2));
  assert.deepEqual(linkTarget(elements, "#group=parent"), [elements[0]]);
  assert.deepEqual(linkTarget(elements, "#element=deleted"), []);
  assert.deepEqual(linkTarget(elements, "#element=missing"), []);
  assert.deepEqual(linkTarget(elements, "#group=missing"), []);
  assert.equal(linkTarget(elements, ""), null);
});

test("selection IDs survive URL encoding", () => {
  const item = { id: "a &日", groupIds: [] };
  const link = selectionLink("excalimacs:/tmp/drawing.excalidraw.png", item.id, "element");
  assert.deepEqual(linkTarget([item], link.slice(link.indexOf("#"))), [item]);
});
