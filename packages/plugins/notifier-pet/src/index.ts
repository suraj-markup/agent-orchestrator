import { createConnection, type Socket } from "node:net";
import { homedir } from "node:os";
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
  version: "0.1.0",
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

export function create(config?: Record<string, unknown>): Notifier {
  const enabled = typeof config?.enabled === "boolean" ? config.enabled : true;
  const rawSocketPath =
    typeof config?.socketPath === "string" && config.socketPath.length > 0
      ? config.socketPath
      : "~/.agent-orchestrator/pet.sock";
  const socketPath = expandHome(rawSocketPath);

  let warned = false;
  const warnOnce = (err: unknown) => {
    if (warned) return;
    warned = true;
    const reason = err instanceof Error ? err.message : String(err);
    console.warn(
      `[notifier-pet] Could not deliver to pet socket at ${socketPath}: ${reason}. ` +
        `Further failures this process will be silenced.`,
    );
  };

  async function deliver(message: WireMessage): Promise<void> {
    if (!enabled) return;
    const line = `${JSON.stringify(message)}\n`;
    try {
      await sendOnce(socketPath, line);
    } catch (err) {
      warnOnce(err);
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
