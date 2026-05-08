import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type * as FsModule from "node:fs";
import type * as NetModule from "node:net";
import type * as OsModule from "node:os";
import type * as ChildProcessModule from "node:child_process";
import type { Server, Socket } from "node:net";
import type { OrchestratorEvent, NotifyAction } from "@aoagents/ao-core";

const realFs = await vi.importActual<typeof FsModule>("node:fs");
const realNet = await vi.importActual<typeof NetModule>("node:net");
const realOs = await vi.importActual<typeof OsModule>("node:os");

vi.mock("node:fs", async (importOriginal) => {
  const actual = await importOriginal<typeof FsModule>();
  return {
    ...actual,
    statSync: vi.fn(actual.statSync),
    accessSync: vi.fn(actual.accessSync),
    readFileSync: vi.fn(actual.readFileSync),
    writeFileSync: vi.fn(actual.writeFileSync),
  };
});

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof ChildProcessModule>();
  return { ...actual, spawn: vi.fn() };
});

const fsMod = await import("node:fs");
const childProcessMod = await import("node:child_process");
const mockedSpawn = childProcessMod.spawn as unknown as ReturnType<typeof vi.fn>;
const mockedStatSync = fsMod.statSync as unknown as ReturnType<typeof vi.fn>;
const mockedAccessSync = fsMod.accessSync as unknown as ReturnType<typeof vi.fn>;
const mockedReadFileSync = fsMod.readFileSync as unknown as ReturnType<typeof vi.fn>;
const mockedWriteFileSync = fsMod.writeFileSync as unknown as ReturnType<typeof vi.fn>;

const { create, manifest } = await import("../index.js");

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
  const socketPath = realFs.realpathSync(dir) + "/" + name;
  const received: string[] = [];
  const sockets = new Set<Socket>();

  const server = realNet.createServer((conn) => {
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
  tmpDir = realFs.mkdtempSync(realOs.tmpdir() + "/ao-notifier-pet-");
  // Reset all mocks and restore real-fs delegation as the default.
  mockedSpawn.mockReset();
  mockedStatSync.mockReset();
  mockedStatSync.mockImplementation(realFs.statSync);
  mockedAccessSync.mockReset();
  mockedAccessSync.mockImplementation(realFs.accessSync);
  mockedReadFileSync.mockReset();
  mockedReadFileSync.mockImplementation(realFs.readFileSync);
  mockedWriteFileSync.mockReset();
  mockedWriteFileSync.mockImplementation(realFs.writeFileSync);
});

afterEach(() => {
  realFs.rmSync(tmpDir, { recursive: true, force: true });
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
    const notifier = create({ socketPath: tmpDir + "/pet.sock", autoLaunch: false });
    expect(notifier.name).toBe("pet");
    expect(typeof notifier.notify).toBe("function");
    expect(typeof notifier.notifyWithActions).toBe("function");
  });

  it("expands ~ in socketPath default without throwing", () => {
    expect(() => create({ autoLaunch: false })).not.toThrow();
  });
});

describe("notifier-pet notify (success path)", () => {
  it("writes one newline-terminated JSON line to the socket and closes", async () => {
    const server = await startServer(tmpDir);
    try {
      const notifier = create({ socketPath: server.socketPath, autoLaunch: false });
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
      const notifier = create({ socketPath: server.socketPath, autoLaunch: false });
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
      const notifier = create({ socketPath: server.socketPath, autoLaunch: false });
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
      const notifier = create({ socketPath: tmpDir + "/missing.sock", autoLaunch: false });
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
      const notifier = create({ socketPath: tmpDir + "/missing.sock", autoLaunch: false });
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
    const socketPath = tmpDir + "/pet.sock";
    const server = realNet.createServer((conn) => {
      // Drop the connection before the client can write.
      conn.destroy();
    });
    await new Promise<void>((resolve) => server.listen(socketPath, () => resolve()));

    try {
      const notifier = create({ socketPath, autoLaunch: false });
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
        socketPath: tmpDir + "/missing.sock",
        enabled: false,
        autoLaunch: false,
      });
      await notifier.notify(makeEvent());
      await notifier.notifyWithActions!(makeEvent(), []);
      expect(warn).not.toHaveBeenCalled();
    } finally {
      warn.mockRestore();
    }
  });
});

describe("notifier-pet auto-launch", () => {
  const originalPlatformDescriptor = Object.getOwnPropertyDescriptor(process, "platform")!;
  const originalEnv = process.env.AOPET_PATH;

  function setPlatform(value: NodeJS.Platform): void {
    Object.defineProperty(process, "platform", { value, configurable: true });
  }

  beforeEach(() => {
    setPlatform("darwin");
    delete process.env.AOPET_PATH;
    // No lockfile by default.
    mockedReadFileSync.mockReset();
    mockedReadFileSync.mockImplementation(() => {
      const err = new Error("ENOENT") as NodeJS.ErrnoException;
      err.code = "ENOENT";
      throw err;
    });
    mockedWriteFileSync.mockReset();
    mockedWriteFileSync.mockImplementation(() => {});
  });

  afterEach(() => {
    Object.defineProperty(process, "platform", originalPlatformDescriptor);
    if (originalEnv === undefined) delete process.env.AOPET_PATH;
    else process.env.AOPET_PATH = originalEnv;
  });

  function fakeChildProcess(pid = 4242): unknown {
    return {
      pid,
      on(_event: string, _handler: (...args: unknown[]) => void) {
        return this;
      },
      unref: vi.fn(),
    };
  }

  function fakeStat(): ReturnType<typeof fsMod.statSync> {
    return { isFile: () => true } as unknown as ReturnType<typeof fsMod.statSync>;
  }

  function enoent(): never {
    const err = new Error("ENOENT") as NodeJS.ErrnoException;
    err.code = "ENOENT";
    throw err;
  }

  it("spawns AOPet with detached:true when binary resolves and autoLaunch is true", () => {
    const explicit = "/Applications/AOPet.app/Contents/MacOS/AOPet";
    mockedStatSync.mockImplementation((path: unknown) => (path === explicit ? fakeStat() : enoent()));
    mockedAccessSync.mockImplementation((path: unknown) => {
      if (path === explicit) return;
      enoent();
    });
    const child = fakeChildProcess();
    mockedSpawn.mockReturnValue(child);

    create({ socketPath: tmpDir + "/pet.sock", autoLaunch: true });

    expect(mockedSpawn).toHaveBeenCalledTimes(1);
    const [calledPath, calledArgs, calledOpts] = mockedSpawn.mock.calls[0]!;
    expect(calledPath).toBe(explicit);
    expect(calledArgs).toEqual([]);
    expect(calledOpts).toMatchObject({ detached: true, stdio: "ignore" });
    expect((child as { unref: ReturnType<typeof vi.fn> }).unref).toHaveBeenCalledTimes(1);
  });

  it("respects an explicit appPath override before defaults", () => {
    const explicit = "/opt/custom/AOPet";
    mockedStatSync.mockImplementation((path: unknown) => (path === explicit ? fakeStat() : enoent()));
    mockedAccessSync.mockImplementation((path: unknown) => {
      if (path === explicit) return;
      enoent();
    });
    mockedSpawn.mockReturnValue(fakeChildProcess());

    create({ appPath: explicit, autoLaunch: true });

    expect(mockedSpawn).toHaveBeenCalledTimes(1);
    expect(mockedSpawn.mock.calls[0]![0]).toBe(explicit);
  });

  it("respects AOPET_PATH env var when no config override is set", () => {
    const envPath = "/srv/AOPet";
    process.env.AOPET_PATH = envPath;
    mockedStatSync.mockImplementation((path: unknown) => (path === envPath ? fakeStat() : enoent()));
    mockedAccessSync.mockImplementation((path: unknown) => {
      if (path === envPath) return;
      enoent();
    });
    mockedSpawn.mockReturnValue(fakeChildProcess());

    create({ autoLaunch: true });

    expect(mockedSpawn).toHaveBeenCalledTimes(1);
    expect(mockedSpawn.mock.calls[0]![0]).toBe(envPath);
  });

  it("does NOT spawn when autoLaunch is false", () => {
    mockedStatSync.mockImplementation(() => fakeStat());
    mockedAccessSync.mockImplementation(() => undefined);

    create({ autoLaunch: false });

    expect(mockedSpawn).not.toHaveBeenCalled();
  });

  it("does NOT spawn when the plugin is disabled", () => {
    mockedStatSync.mockImplementation(() => fakeStat());
    mockedAccessSync.mockImplementation(() => undefined);

    create({ enabled: false, autoLaunch: true });

    expect(mockedSpawn).not.toHaveBeenCalled();
  });

  it("does NOT spawn on non-darwin platforms", () => {
    setPlatform("linux");
    mockedStatSync.mockImplementation(() => fakeStat());
    mockedAccessSync.mockImplementation(() => undefined);

    create({ autoLaunch: true });

    expect(mockedSpawn).not.toHaveBeenCalled();
  });

  it("logs a single warning and does NOT spawn when no binary is found", () => {
    mockedStatSync.mockImplementation(() => enoent());
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      create({ autoLaunch: true });
      expect(mockedSpawn).not.toHaveBeenCalled();
      expect(warn).toHaveBeenCalledTimes(1);
      expect(warn.mock.calls[0]![0]).toMatch(/AOPet binary not found/);
    } finally {
      warn.mockRestore();
    }
  });

  it("does NOT spawn when an existing AOPet pid in the lockfile is still alive", () => {
    mockedReadFileSync.mockImplementation(() => `${process.pid}\n`);
    mockedStatSync.mockImplementation(() => fakeStat());
    mockedAccessSync.mockImplementation(() => undefined);

    create({ autoLaunch: true });

    expect(mockedSpawn).not.toHaveBeenCalled();
  });
});
