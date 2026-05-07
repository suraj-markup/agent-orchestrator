import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createServer, type Server, type Socket } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { OrchestratorEvent, NotifyAction } from "@aoagents/ao-core";
import { create, manifest } from "../index.js";

function makeEvent(overrides: Partial<OrchestratorEvent> = {}): OrchestratorEvent {
  return {
    id: "evt-1",
    type: "session.spawned",
    priority: "info",
    sessionId: "app-1",
    projectId: "my-project",
    timestamp: new Date("2025-01-01T00:00:00Z"),
    message: "Session app-1 spawned",
    data: { foo: "bar" },
    ...overrides,
  };
}

interface RunningServer {
  server: Server;
  socketPath: string;
  received: string[];
  cleanup: () => Promise<void>;
}

async function startServer(dir: string, name = "pet.sock"): Promise<RunningServer> {
  const socketPath = join(dir, name);
  const received: string[] = [];
  const sockets = new Set<Socket>();

  const server = createServer((conn) => {
    sockets.add(conn);
    let buf = "";
    conn.on("data", (chunk) => {
      buf += chunk.toString("utf8");
    });
    conn.on("end", () => {
      if (buf.length > 0) received.push(buf);
      sockets.delete(conn);
    });
    conn.on("close", () => {
      sockets.delete(conn);
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, () => resolve());
  });

  return {
    server,
    socketPath,
    received,
    async cleanup() {
      for (const s of sockets) s.destroy();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

async function waitForReceive(server: RunningServer, expected = 1, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (server.received.length < expected) {
    if (Date.now() > deadline) {
      throw new Error(
        `Timed out waiting for ${expected} message(s); received ${server.received.length}`,
      );
    }
    await new Promise((r) => setTimeout(r, 10));
  }
}

let tmpDir: string;

beforeEach(() => {
  tmpDir = mkdtempSync(join(tmpdir(), "ao-notifier-pet-"));
});

afterEach(() => {
  rmSync(tmpDir, { recursive: true, force: true });
});

describe("notifier-pet manifest", () => {
  it("has correct name and slot", () => {
    expect(manifest.name).toBe("pet");
    expect(manifest.slot).toBe("notifier");
    expect(manifest.description).toMatch(/pet/i);
    expect(typeof manifest.version).toBe("string");
  });
});

describe("notifier-pet create", () => {
  it("returns a notifier with the expected shape", () => {
    const notifier = create({ socketPath: join(tmpDir, "pet.sock") });
    expect(notifier.name).toBe("pet");
    expect(typeof notifier.notify).toBe("function");
    expect(typeof notifier.notifyWithActions).toBe("function");
  });

  it("expands ~ in socketPath default without throwing", () => {
    expect(() => create()).not.toThrow();
  });
});

describe("notifier-pet notify (success path)", () => {
  it("writes one newline-terminated JSON line to the socket and closes", async () => {
    const server = await startServer(tmpDir);
    try {
      const notifier = create({ socketPath: server.socketPath });
      await notifier.notify(makeEvent());
      await waitForReceive(server);

      expect(server.received).toHaveLength(1);
      const raw = server.received[0]!;
      expect(raw.endsWith("\n")).toBe(true);
      const parsed = JSON.parse(raw.trimEnd()) as Record<string, unknown>;

      expect(parsed).toEqual({
        v: 1,
        kind: "event",
        event: {
          id: "evt-1",
          type: "session.spawned",
          priority: "info",
          sessionId: "app-1",
          projectId: "my-project",
          timestamp: "2025-01-01T00:00:00.000Z",
          message: "Session app-1 spawned",
          data: { foo: "bar" },
        },
      });
      expect(Object.keys(parsed)).not.toContain("actions");
    } finally {
      await server.cleanup();
    }
  });

  it("opens a fresh connection for each notify call (no pooling)", async () => {
    const server = await startServer(tmpDir);
    try {
      const notifier = create({ socketPath: server.socketPath });
      await notifier.notify(makeEvent({ id: "a" }));
      await notifier.notify(makeEvent({ id: "b" }));
      await notifier.notify(makeEvent({ id: "c" }));
      await waitForReceive(server, 3);

      expect(server.received).toHaveLength(3);
      const ids = server.received.map((r) => (JSON.parse(r.trimEnd()) as { event: { id: string } }).event.id);
      expect(ids).toEqual(["a", "b", "c"]);
    } finally {
      await server.cleanup();
    }
  });
});

describe("notifier-pet notifyWithActions (success path)", () => {
  it("includes actions array with {label, action} entries", async () => {
    const server = await startServer(tmpDir);
    try {
      const notifier = create({ socketPath: server.socketPath });
      const actions: NotifyAction[] = [
        { label: "Open PR", url: "https://github.com/pr/1" },
        { label: "Kill", callbackEndpoint: "/api/kill" },
      ];
      await notifier.notifyWithActions!(makeEvent({ priority: "action" }), actions);
      await waitForReceive(server);

      const parsed = JSON.parse(server.received[0]!.trimEnd()) as {
        v: number;
        kind: string;
        actions: Array<{ label: string; action: string }>;
      };
      expect(parsed.v).toBe(1);
      expect(parsed.kind).toBe("event");
      expect(parsed.actions).toEqual([
        { label: "Open PR", action: "https://github.com/pr/1" },
        { label: "Kill", action: "/api/kill" },
      ]);
    } finally {
      await server.cleanup();
    }
  });
});

describe("notifier-pet graceful fallback", () => {
  it("does not throw when the socket file does not exist (ENOENT)", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const notifier = create({ socketPath: join(tmpDir, "missing.sock") });
      await expect(notifier.notify(makeEvent())).resolves.toBeUndefined();
      expect(warn).toHaveBeenCalledTimes(1);
      expect(warn.mock.calls[0]![0]).toMatch(/notifier-pet/);
    } finally {
      warn.mockRestore();
    }
  });

  it("warns only once per process across many failures", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const notifier = create({ socketPath: join(tmpDir, "missing.sock") });
      await notifier.notify(makeEvent());
      await notifier.notify(makeEvent());
      await notifier.notifyWithActions!(makeEvent(), [{ label: "X", url: "https://x" }]);
      expect(warn).toHaveBeenCalledTimes(1);
    } finally {
      warn.mockRestore();
    }
  });

  it("swallows write errors when the server hangs up immediately", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const socketPath = join(tmpDir, "pet.sock");
    const server = createServer((conn) => {
      // Drop the connection before the client can write.
      conn.destroy();
    });
    await new Promise<void>((resolve) => server.listen(socketPath, () => resolve()));

    try {
      const notifier = create({ socketPath });
      await expect(notifier.notify(makeEvent())).resolves.toBeUndefined();
    } finally {
      await new Promise<void>((resolve) => server.close(() => resolve()));
      warn.mockRestore();
    }
  });

  it("is a no-op when enabled=false (no warning, no throw)", async () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const notifier = create({
        socketPath: join(tmpDir, "missing.sock"),
        enabled: false,
      });
      await notifier.notify(makeEvent());
      await notifier.notifyWithActions!(makeEvent(), []);
      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });
});
