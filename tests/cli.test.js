import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

for (const state of ["cancelled", "running", "finished"]) {
  test(`CLI timeout reports ${state} accurately`, () => {
    const scratch = mkdtempSync(join(tmpdir(), "excalimacs-cli-"));
    try {
      const bin = join(scratch, "bin");
      mkdirSync(bin);
      const executable = (name, body) => writeFileSync(join(bin, name),
        `#!/bin/sh\n${body}\n`, { mode: 0o755 });
      // Force timeout after one poll, then simulate the server's cancellation reply.
      executable("seq", "echo 1");
      executable("sleep", "exit 0");
      executable("emacsclient", `case "$2" in
  '(excalimacs-agent-submit '*) echo '\"test-id\"' ;;
  '(excalimacs-agent-result '*)
    if [ -e "$EXCALIMACS_TEST_MARKER" ]; then echo ok; else echo nil; fi ;;
  '(excalimacs-agent-cancel '*)
    : > "$EXCALIMACS_TEST_MARKER"
    echo "$EXCALIMACS_TEST_CANCEL" ;;
esac`);
      const result = spawnSync(fileURLToPath(new URL("../bin/excalimacs", import.meta.url)),
        ["scene", join(scratch, "drawing.excalidraw.png")], {
          encoding: "utf8", env: { ...process.env, PATH: `${bin}:${process.env.PATH}`,
            EXCALIMACS_TEST_MARKER: join(scratch, "cancelled"), EXCALIMACS_TEST_CANCEL: state },
        });
      assert.equal(result.status, state === "finished" ? 0 : 1, result.stderr);
      if (state === "cancelled") assert.match(result.stderr, /cancelled before execution/);
      if (state === "running") {
        assert.match(result.stderr, /already executing and may still complete/);
        assert.doesNotMatch(result.stderr, /cancelled/);
      }
      if (state === "finished") assert.equal(result.stderr, "");
    } finally {
      execFileSync("trash", [scratch]);
    }
  });
}
