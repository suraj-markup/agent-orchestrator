import { spawn, type SpawnOptions } from "node:child_process";
import { accessSync, constants as fsConstants, readFileSync, statSync, writeFileSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  type PluginModule,
  type Notifier,
  type OrchestratorEvent,
  type NotifyAction,
} from "@aoagents/ao-core";

export const manifest = {
  name: "pet",
  slot: "notifier" as const,
  description: "Notifier plugin: Unix socket bridge to the macOS pet overlay app",
  version: "0.2.0",
};

const WIRE_VERSION = 1 as const;

interface WireAction {
  label: string;
  action: string;
}

interface WireEvent {
  id: string;
  type: string;
  priority: string;
  sessionId: string;
  projectId: string;
  timestamp: string;
  message: string;
  data: Record<string, unknown>;
}

interface WireMessage {
  v: typeof WIRE_VERSION;
  kind: "event";
  event: WireEvent;
  actions?: WireAction[];
}

function expandHome(p: string): string {
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return `${homedir()}/${p.slice(2)}`;
  return p;
}

function serializeEvent(event: OrchestratorEvent): WireEvent {
  return {
    id: event.id,
    type: event.type,
    priority: event.priority,
    sessionId: event.sessionId,
    projectId: event.projectId,
    timestamp: event.timestamp.toISOString(),
    message: event.message,
    data: event.data,
  };
}

function serializeAction(action: NotifyAction): WireAction {
  // The pet app's wire contract uses a single `action` string. Prefer the
  // explicit callback endpoint (server-side trigger) and fall back to the URL
  // (link-out) so the pet always has something to fire when the user clicks.
  return {
    label: action.label,
    action: action.callbackEndpoint ?? action.url ?? "",
  };
}

function sendOnce(socketPath: string, line: string): Promise<void> {
  return new Promise((resolve, reject) => {
    let socket: Socket;
    try {
      socket = createConnection(socketPath);
    } catch (err) {
      reject(err instanceof Error ? err : new Error(String(err)));
      return;
    }

    let settled = false;
    const finish = (err?: Error) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      if (err) reject(err);
      else resolve();
    };

    socket.once("error", finish);
    socket.once("connect", () => {
      socket.end(line, () => finish());
    });
  });
}

const PID_LOCKFILE = expandHome("~/.agent-orchestrator/aopet.pid");

function isExecutableFile(path: string): boolean {
  try {
    const st = statSync(path);
    if (!st.isFile()) return false;
    accessSync(path, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveAopetBinary(explicit: string | undefined, cwd: string, home: string): string | null {
  const candidates: string[] = [];
  if (explicit && explicit.length > 0) candidates.push(expandHome(explicit));
  if (process.env.AOPET_PATH && process.env.AOPET_PATH.length > 0) {
    candidates.push(expandHome(process.env.AOPET_PATH));
  }
  candidates.push(
    "/Applications/AOPet.app/Contents/MacOS/AOPet",
    join(home, "Applications/AOPet.app/Contents/MacOS/AOPet"),
    "/usr/local/bin/AOPet",
    join(cwd, "apps/pet-mac/.build/release/AOPet"),
    join(cwd, "apps/pet-mac/.build/debug/AOPet"),
  );

  for (const candidate of candidates) {
    if (isExecutableFile(candidate)) return candidate;
  }
  return null;
}

function isPidAlive(pid: number): boolean {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM means the process exists but we can't signal it — still alive.
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

function readLockfilePid(path: string): number | null {
  try {
    const raw = readFileSync(path, "utf8").trim();
    const pid = Number.parseInt(raw, 10);
    return Number.isFinite(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

function writeLockfile(path: string, pid: number): void {
  try {
    writeFileSync(path, `${pid}\n`, { encoding: "utf8", mode: 0o644 });
  } catch {
    // Lockfile is a best-effort optimization. If we can't write it, just skip —
    // worst case we re-launch AOPet on the next ao start while one is already up.
  }
}

interface AutoLaunchOptions {
  appPath?: string;
  pidFile: string;
  cwd: string;
  home: string;
  warn: (message: string) => void;
}

function tryAutoLaunch(opts: AutoLaunchOptions): void {
  if (process.platform !== "darwin") return;

  const existingPid = readLockfilePid(opts.pidFile);
  if (existingPid !== null && isPidAlive(existingPid)) return;

  const binary = resolveAopetBinary(opts.appPath, opts.cwd, opts.home);
  if (!binary) {
    opts.warn(
      "[notifier-pet] AOPet binary not found; install AOPet.app or set notifiers.pet.appPath / AOPET_PATH.",
    );
    return;
  }

  try {
    const spawnOpts: SpawnOptions = { detached: true, stdio: "ignore" };
    const child = spawn(binary, [], spawnOpts);
    child.on("error", () => {
      // Swallow — AOPet failures must never propagate into the orchestrator.
    });
    if (typeof child.pid === "number") {
      writeLockfile(opts.pidFile, child.pid);
    }
    child.unref();
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    opts.warn(`[notifier-pet] Failed to launch AOPet at ${binary}: ${reason}`);
  }
}

export function create(config?: Record<string, unknown>): Notifier {
  const enabled = typeof config?.enabled === "boolean" ? config.enabled : true;
  const autoLaunch = typeof config?.autoLaunch === "boolean" ? config.autoLaunch : true;
  const appPath =
    typeof config?.appPath === "string" && config.appPath.length > 0 ? config.appPath : undefined;
  const rawSocketPath =
    typeof config?.socketPath === "string" && config.socketPath.length > 0
      ? config.socketPath
      : "~/.agent-orchestrator/pet.sock";
  const socketPath = expandHome(rawSocketPath);

  let socketWarned = false;
  const warnSocketOnce = (err: unknown) => {
    if (socketWarned) return;
    socketWarned = true;
    const reason = err instanceof Error ? err.message : String(err);
    console.warn(
      `[notifier-pet] Could not deliver to pet socket at ${socketPath}: ${reason}. ` +
        `Further failures this process will be silenced.`,
    );
  };

  let launchWarned = false;
  const warnLaunchOnce = (message: string) => {
    if (launchWarned) return;
    launchWarned = true;
    console.warn(message);
  };

  if (enabled && autoLaunch) {
    tryAutoLaunch({
      appPath,
      pidFile: PID_LOCKFILE,
      cwd: process.cwd(),
      home: homedir(),
      warn: warnLaunchOnce,
    });
  }

  async function deliver(message: WireMessage): Promise<void> {
    if (!enabled) return;
    const line = `${JSON.stringify(message)}\n`;
    try {
      await sendOnce(socketPath, line);
    } catch (err) {
      warnSocketOnce(err);
    }
  }

  return {
    name: "pet",

    async notify(event: OrchestratorEvent): Promise<void> {
      await deliver({
        v: WIRE_VERSION,
        kind: "event",
        event: serializeEvent(event),
      });
    },

    async notifyWithActions(event: OrchestratorEvent, actions: NotifyAction[]): Promise<void> {
      await deliver({
        v: WIRE_VERSION,
        kind: "event",
        event: serializeEvent(event),
        actions: actions.map(serializeAction),
      });
    },
  };
}

export default { manifest, create } satisfies PluginModule<Notifier>;
