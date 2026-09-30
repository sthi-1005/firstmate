import { lstatSync, readFileSync } from "node:fs";

// Pi primary evidence admission, shared by the watcher and turn-end extensions.
// Factories only register hooks: information-only CLI invocations load factories
// (including explicit -e) but never start a session. Publish evidence from
// session_start or an owning session's tool, never from factory evaluation.
// A started primary may publish pre-lock evidence when its lock is absent/dead;
// arming still requires exact ownership. fm-lock.sh records the inner Pi engine
// pid, including pi-signed, not its wrapper or an arbitrary ancestor. Therefore
// a nested Pi session must not borrow the parent's lock. No ps ancestry walk is
// needed, which also avoids mixing native Windows and MSYS process identities.
// FM_TASK_ID marks ship/scout workers, not secondmates (fm-spawn.sh); it denies
// primary evidence only, leaving the turn-end extension's worker hooks intact.
export type PiPrimaryLockOwnership = "owned" | "missing" | "other";

export function piPrimaryLockOwnership(state: string): PiPrimaryLockOwnership {
  if (process.env.FM_TASK_ID) return "other";
  let lockPid: string;
  try {
    if (!lstatSync(`${state}/.lock`).isFile()) return "other";
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? "missing" : "other";
  }
  if (!/^[1-9][0-9]*$/.test(lockPid)) return "other";
  const pid = Number(lockPid);
  if (!Number.isSafeInteger(pid) || pid <= 1) return "other";
  if (pid === process.pid) return "owned";
  try {
    process.kill(pid, 0);
    return "other";
  } catch (error) {
    // Only ESRCH proves absence. EPERM or an inspection failure is not consent.
    return (error as NodeJS.ErrnoException).code === "ESRCH" ? "missing" : "other";
  }
}
