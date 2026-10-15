import { execFileSync, spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const suites = {
  animation: "agent-animation-browser.cjs", pens: "pens-browser.cjs",
  links: "drawing-links-browser.cjs", editor: "editor-browser.cjs",
};
const selected = process.argv.slice(2);
if (selected.some((name) => !suites[name])) throw new Error("Unknown browser suite");
const scratch = await mkdtemp(join(tmpdir(), "excalimacs-tests-"));
const socket = `excalimacs-tests-${process.pid}`;
const emacsclient = execFileSync("sh", ["-c", "command -v emacsclient"], { encoding: "utf8" }).trim();
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`;
let started = false;
try {
  // The CLI and existing suites use emacsclient; route them to a disposable Emacs.
  await mkdir(join(scratch, "bin"));
  const wrapper = join(scratch, "bin", "emacsclient");
  await writeFile(wrapper, `#!/bin/sh\nexec ${quote(emacsclient)} --socket-name=${quote(socket)} "$@"\n`);
  await chmod(wrapper, 0o755);
  execFileSync("emacs", ["-Q", `--daemon=${socket}`, "-L", root,
    "-L", join(root, "../emacs-web-server.github.skeeto"),
    "--eval", `(setq user-emacs-directory ${JSON.stringify(scratch + "/")})`,
    "-l", join(root, "excalimacs.el")], { stdio: "inherit" });
  started = true;
  for (const name of selected.length ? selected : Object.keys(suites)) {
    console.log(`Browser suite: ${name}`);
    await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [join(root, "tests", suites[name])], {
        cwd: root, stdio: "inherit", timeout: 180000,
        env: { ...process.env, PATH: `${join(scratch, "bin")}:${process.env.PATH}` },
      });
      child.on("error", reject);
      child.on("exit", (code, signal) => code === 0 ? resolve()
        : reject(new Error(`${name}: exit ${code}, signal ${signal}`)));
    });
  }
} finally {
  try {
    if (started) execFileSync(emacsclient, [`--socket-name=${socket}`, "--eval", "(kill-emacs)"]);
  } finally {
    execFileSync("trash", [scratch]);
  }
}
