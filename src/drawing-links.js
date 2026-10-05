// Resolve saved IDs against the current scene, so links follow moved elements.
export function linkTarget(elements, hash) {
  const params = new URLSearchParams(hash.replace(/^#/, ""));
  const element = params.get("element");
  const group = params.get("group");
  if (!element && !group) return null;
  return elements.filter((item) => !item.isDeleted &&
    (element ? item.id === element : item.groupIds?.includes(group)));
}

export function selectionLink(link, id, type) {
  return `${link}#${type}=${encodeURIComponent(id)}`;
}
