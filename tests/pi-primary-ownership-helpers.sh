#!/usr/bin/env bash
# Token-free real-Pi admission guard, sourced by fm-pi-primary-live-e2e.test.sh.
# Every process, home, marker, and shell script belongs to this private lab.
run_pi_primary_ownership_live() (
  fm_live_gate default-on FM_PI_PRIMARY_OWNERSHIP_LIVE node
  local lab harness checked=0
  lab=$(fm_test_tmproot fm-pi-primary-ownership-live)
  mkdir -p "$lab/project/.pi/extensions" "$lab/project/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$lab/project/.pi/extensions/"
  cp -R "$ROOT/.pi/extensions/lib" "$lab/project/.pi/extensions/"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$lab/project/bin/fm-sessionstart-run.sh"
  cat > "$lab/project/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
exec node "$FM_PROBE_ARM"
SH
  cat > "$lab/arm.mjs" <<'JS'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const path = `${process.env.FM_HOME}/state/probe-arm`;
const previous = existsSync(path) ? Number(readFileSync(path, "utf8")) : 0;
writeFileSync(path, String(process.pid));
console.log(`watcher: started pid=${process.pid}`);
// Model the real arm's successor commit followed by predecessor retirement.
if (previous > 1 && previous !== process.pid) {
  try { process.kill(previous, "SIGTERM"); } catch {}
}
const parent = process.ppid;
setInterval(() => {
  if (!existsSync(path)) process.exit(0);
  try { process.kill(parent, 0); } catch { process.exit(0); }
}, 100);
JS
  chmod +x "$lab/project/bin/"*.sh
  git init -q "$lab/project"
  printf '# Isolated Pi ownership lab\n' > "$lab/project/AGENTS.md"
  cat > "$lab/setup.ts" <<'TS'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
export default function (pi) {
  // Only the initial CLI prepares its synthetic lock. Nested probes inherit
  // the parent's live lock without any test extension repairing it for them.
  if (!process.env.FM_PROBE_CHILD) {
    const state = `${process.env.FM_HOME}/state`;
    if (process.env.FM_PROBE_LOCK !== "fresh") mkdirSync(state, { recursive: true });
    if (process.env.FM_PROBE_LOCK === "exact") writeFileSync(`${state}/.lock`, `${process.pid}\n`);
    if (process.env.FM_PROBE_LOCK === "absent") rmSync(`${state}/.lock`, { force: true });
    if (process.env.FM_PROBE_LOCK === "acquire") {
      const claim = spawnSync("bash", [process.env.FM_PROBE_LOCK_SCRIPT], { encoding: "utf8", timeout: 20000 });
      assert.equal(claim.status, 0, claim.stderr + claim.stdout);
      assert.equal(readFileSync(`${state}/.lock`, "utf8").trim(), String(process.pid), "real lock owner is not the Pi engine");
    }
  }
  pi.registerProvider("fm-probe", {
    baseUrl: "http://127.0.0.1:1", apiKey: "unused", api: "openai-completions",
    models: [{ id: "token-free", name: "Offline ownership probe", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 4096, maxTokens: 128 }],
    streamSimple() { throw new Error("ownership guard must never request a model turn"); },
  });
}
TS
  cat > "$lab/probe.ts" <<'TS'
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
export default function (pi) {
  const state = `${process.env.FM_HOME}/state`;
  const markers = [".pi-watch-extension-loaded", ".pi-turnend-extension-loaded"].map(p => join(state, p));
  const snapshot = () => markers.map(p => existsSync(p) ? readFileSync(p, "utf8") : null);
  if (process.env.FM_PROBE_CHILD) {
    writeFileSync(process.env.FM_PROBE_CHILD, "factory-loaded\n");
    return;
  }
  const record = (row) => writeFileSync(process.env.FM_PROBE_RECORD, `${JSON.stringify(row)}\n`, { flag: "a" });
  record({ kind: "factory", markers: snapshot(), pid: process.pid });
  pi.on("session_start", (event) => record({ kind: event.reason, markers: snapshot(), pid: process.pid }));
  const check = () => {
    if (process.env.FM_PROBE_ADMIT === "yes") {
      for (const content of snapshot()) assert.equal(content?.split("\n")[1], String(process.pid), "started primary did not publish its engine pid");
    } else {
      assert.deepEqual(snapshot(), ["sentinel-watch\n", "sentinel-turnend\n"], "ineligible session changed evidence");
    }
  };
  pi.registerCommand("fm-reload", { handler: async (_args, ctx) => { check(); await ctx.reload(); } });
  pi.registerCommand("fm-probe", { handler: async () => {
    check();
    if (process.env.FM_PROBE_NESTED === "yes") {
      const original = snapshot();
      const lock = `${state}/.lock`;
      const originalLock = existsSync(lock) ? readFileSync(lock, "utf8") : null;
      const dead = spawnSync("node", ["-e", "process.stdout.write(String(process.pid))"], { encoding: "utf8" });
      assert.equal(dead.status, 0);
      for (const [kind, value] of [["ancestor", `${process.pid}\n`], ["absent", null], ["dead", dead.stdout], ["malformed", "bad\n"]]) {
        if (value === null) rmSync(lock, { force: true }); else writeFileSync(lock, value);
        for (const flag of ["--help", "--list-models"]) {
          const childProof = `${state}/probe-child`;
          rmSync(childProof, { force: true });
          const args = ["--no-session", "--no-context-files", "--no-skills", "--no-extensions", "--no-approve",
            "-e", process.env.FM_PROBE_SETUP,
            "-e", join(process.cwd(), ".pi/extensions/fm-primary-pi-watch.ts"),
            "-e", join(process.cwd(), ".pi/extensions/fm-primary-turnend-guard.ts"),
            "-e", process.env.FM_PROBE_EXTENSION, flag];
          if (flag === "--list-models") args.push("token-free");
          const child = spawnSync(process.env.FM_PROBE_BINARY, args, {
            cwd: process.cwd(), encoding: "utf8", timeout: 20000,
            env: { ...process.env, FM_PROBE_CHILD: childProof },
          });
          assert.equal(child.status, 0, `${kind} ${flag}: ${child.error ?? child.stderr}`);
          assert.ok(!/Failed to load extension|Error loading extension/i.test(child.stderr + child.stdout), child.stderr);
          assert.ok(existsSync(childProof), `${flag} did not exercise factory loading`);
          if (flag === "--list-models") assert.match(child.stdout, /token-free/, "extension model disappeared from discovery");
          assert.deepEqual(snapshot(), original, `${kind} ${flag} changed parent evidence`);
          record({ kind: `nested ${kind} ${flag}` });
        }
      }
      if (originalLock === null) rmSync(lock, { force: true }); else writeFileSync(lock, originalLock);
    }
    record({ kind: "checked", markers: snapshot(), pid: process.pid });
  } });
}
TS
  for harness in pi pi-signed; do
    if ! command -v "$harness" >/dev/null 2>&1; then
      printf '# unavailable primary ownership harness: %s\n' "$harness"
      continue
    fi
    checked=$((checked + 1))
    FM_PROBE_LAB="$lab" FM_PROBE_BINARY="$(command -v "$harness")" FM_PROBE_HARNESS="$harness" FM_PROBE_LOCK_SCRIPT="$ROOT/bin/fm-lock.sh" node --input-type=module <<'JS' || exit 1
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const lab = process.env.FM_PROBE_LAB;
const binary = process.env.FM_PROBE_BINARY;
const harness = process.env.FM_PROBE_HARNESS;
const home = join(lab, harness);
mkdirSync(home, { recursive: true });
// Deliberately no ambient credentials, personal packages, trust store, or FM
// overrides. Extension-registered fake credentials can never reach a transport.
const baseEnv = { PATH: process.env.PATH, HOME: home, TERM: "dumb", PI_OFFLINE: "1",
  PI_CODING_AGENT_DIR: join(home, "agent"), FM_PROBE_BINARY: binary, FM_PI_HARNESS: harness,
  FM_PROBE_SETUP: join(lab, "setup.ts"), FM_PROBE_EXTENSION: join(lab, "probe.ts"), FM_PROBE_ARM: join(lab, "arm.mjs"),
  FM_PROBE_LOCK_SCRIPT: process.env.FM_PROBE_LOCK_SCRIPT,
};
// Windows needs these OS paths, not user credentials or personal Pi settings.
for (const name of ["SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TMPDIR", "TMP", "TEMP"])
  if (process.env[name]) baseEnv[name] = process.env[name];
const versionResult = spawnSync(binary, ["--version"], { env: baseEnv, encoding: "utf8", timeout: 20000 });
assert.equal(versionResult.status, 0, `${harness} version: ${versionResult.stderr}`);
const version = versionResult.stdout.trim();
try {
  for (const [name, lock, admit, trust, worker] of [
    ["fresh-home", "fresh", true, "explicit", false],
    ["pre-lock", "absent", true, "explicit", false],
    ["exact-reload-nested", "acquire", true, "explicit", false],
    ["trusted-discovery", "acquire", true, "yes", false],
    ["untrusted-discovery", "acquire", false, "no", false],
    ["worker", "exact", false, "explicit", true],
    ["secondmate", "acquire", true, "explicit", false],
  ]) {
    const fmHome = join(home, name);
    const state = join(fmHome, "state");
    if (lock !== "fresh") mkdirSync(state, { recursive: true });
    mkdirSync(join(fmHome, "config"), { recursive: true });
    if (name === "secondmate") writeFileSync(join(fmHome, ".fm-secondmate-home"), "test-secondmate\n");
    const markers = [".pi-watch-extension-loaded", ".pi-turnend-extension-loaded"].map(p => join(state, p));
    const sentinels = lock === "fresh" ? [null, null] : ["sentinel-watch\n", "sentinel-turnend\n"];
    if (lock !== "fresh") markers.forEach((p, i) => writeFileSync(p, sentinels[i]));
    const record = join(fmHome, "events");
    const args = ["--print", "--no-session", "--no-context-files", "--no-skills", trust === "yes" ? "--approve" : "--no-approve",
      "-e", baseEnv.FM_PROBE_SETUP];
    // Match secondmate launch order, including a turn-end hook before the
    // watcher has had any opportunity to create a fresh home's state directory.
    if (trust === "explicit") args.push("--no-extensions", "-e", join(lab, "project/.pi/extensions/fm-primary-turnend-guard.ts"), "-e", join(lab, "project/.pi/extensions/fm-primary-pi-watch.ts"));
    args.push("-e", baseEnv.FM_PROBE_EXTENSION, "--model", "fm-probe/token-free");
    if (name === "exact-reload-nested") args.push("/fm-reload");
    args.push("/fm-probe");
    const env = { ...baseEnv, FM_HOME: fmHome, FM_ROOT_OVERRIDE: join(lab, "project"), FM_PROBE_RECORD: record,
      FM_PROBE_LOCK: lock, FM_PROBE_ADMIT: admit ? "yes" : "no", FM_PROBE_NESTED: name === "exact-reload-nested" ? "yes" : "no" };
    if (worker) env.FM_TASK_ID = "fixture-worker";
    const run = spawnSync(binary, args, { cwd: join(lab, "project"), env, encoding: "utf8", timeout: 120000 });
    assert.equal(run.status, 0, `${name}: ${run.error ?? ""} ${run.stderr} ${run.stdout}\n${existsSync(record) ? readFileSync(record, "utf8") : "no events"}`);
    assert.ok(!/Failed to load extension|Error loading extension/i.test(run.stderr + run.stdout), run.stderr);
    const rows = readFileSync(record, "utf8").trim().split("\n").map(row => JSON.parse(row));
    assert.deepEqual(rows[0].markers, sentinels, `${name}: factories changed markers before session admission`);
    assert.ok(rows.some(row => row.kind === "checked"), `${name}: command did not execute`);
    if (name === "exact-reload-nested") {
      const initial = rows.find(row => row.kind === "startup");
      const replacement = rows.find(row => row.kind === "reload");
      assert.ok(initial && replacement, "reload events absent");
      assert.notEqual(initial.markers[0], replacement.markers[0], "reload reused watcher generation");
      assert.match(replacement.markers[0], /phase=active/, "reload left handoff evidence");
      assert.equal(rows.filter(row => row.kind.startsWith("nested ")).length, 8, "nested matrix incomplete");
    }
    if (!admit) assert.deepEqual(markers.map(p => readFileSync(p, "utf8")), sentinels, `${name}: shutdown changed evidence`);
    // Each separate home leaves every other home's records intact.
    if (name === "secondmate") assert.equal(readFileSync(join(home, "worker/state/.pi-watch-extension-loaded"), "utf8"), sentinels[0]);
    console.log(`ok - ${harness} ${version} token-free primary ownership: ${name}`);
  }
} catch (error) {
  console.error(`not ok - ${harness} ${version} primary ownership: ${error.stack ?? error}`);
  process.exitCode = 1;
}
JS
  done
  if [ "$checked" -eq 0 ]; then
    fm_live_gate default-on FM_PI_PRIMARY_OWNERSHIP_LIVE pi
    fail "primary ownership guard checked no harness"
  fi
)
