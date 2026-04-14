/**
 * Unit tests for findConfigFile — specifically covering XDG fallback paths.
 *
 * These tests override HOME/XDG_CONFIG_HOME to sandboxed temp dirs and
 * chdir into a dir with no upward config so the home-fallback branch runs.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { findConfigFile, getConfigSearchPaths } from "../config.js";

/**
 * Node's `os.homedir()` reads $HOME at call time on POSIX, but several of
 * these fallback tests chdir to a sandbox dir that has no ancestors in a
 * repo checkout (so searchUpTree returns null) and rely on a custom HOME.
 *
 * We drive the XDG_CONFIG_HOME branch directly to avoid coupling to the
 * behavior of `os.homedir()` across platforms, and verify one real-homedir
 * search path via getConfigSearchPaths().
 */
describe("findConfigFile — XDG_CONFIG_HOME override", () => {
  let tmpRoot: string;
  let fakeXdg: string;
  let scratchCwd: string;
  const origEnv = { ...process.env };
  const origCwd = process.cwd();

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "ao-config-find-"));
    fakeXdg = join(tmpRoot, "xdg");
    // Sandbox with no config anywhere up the tree.
    scratchCwd = join(tmpRoot, "work");
    mkdirSync(fakeXdg, { recursive: true });
    mkdirSync(scratchCwd, { recursive: true });

    delete process.env.AO_CONFIG_PATH;
    process.env.XDG_CONFIG_HOME = fakeXdg;
    process.chdir(scratchCwd);
  });

  afterEach(() => {
    process.chdir(origCwd);
    process.env = { ...origEnv };
    rmSync(tmpRoot, { recursive: true, force: true });
  });

  it("finds XDG config at $XDG_CONFIG_HOME/agent-orchestrator/agent-orchestrator.yaml", () => {
    const xdgDir = join(fakeXdg, "agent-orchestrator");
    mkdirSync(xdgDir, { recursive: true });
    const expected = join(xdgDir, "agent-orchestrator.yaml");
    writeFileSync(expected, "projects: {}\n");

    expect(findConfigFile()).toBe(expected);
  });

  it("finds legacy $XDG_CONFIG_HOME/agent-orchestrator/config.yaml", () => {
    const xdgDir = join(fakeXdg, "agent-orchestrator");
    mkdirSync(xdgDir, { recursive: true });
    const expected = join(xdgDir, "config.yaml");
    writeFileSync(expected, "projects: {}\n");

    expect(findConfigFile()).toBe(expected);
  });

  it("prefers agent-orchestrator.yaml over config.yaml when both exist", () => {
    const xdgDir = join(fakeXdg, "agent-orchestrator");
    mkdirSync(xdgDir, { recursive: true });
    const primary = join(xdgDir, "agent-orchestrator.yaml");
    const legacy = join(xdgDir, "config.yaml");
    writeFileSync(primary, "projects: {}\n");
    writeFileSync(legacy, "projects: {}\n");

    expect(findConfigFile()).toBe(primary);
  });

  it("returns null when no config exists in any fallback location", () => {
    expect(findConfigFile()).toBeNull();
  });
});

describe("getConfigSearchPaths", () => {
  const origEnv = { ...process.env };

  afterEach(() => {
    process.env = { ...origEnv };
  });

  it("includes the XDG agent-orchestrator.yaml path ahead of config.yaml", () => {
    delete process.env.XDG_CONFIG_HOME;
    const paths = getConfigSearchPaths();
    const xdgIdx = paths.findIndex((p) =>
      p.endsWith(join("agent-orchestrator", "agent-orchestrator.yaml")),
    );
    const legacyIdx = paths.findIndex((p) =>
      p.endsWith(join("agent-orchestrator", "config.yaml")),
    );
    expect(xdgIdx).toBeGreaterThanOrEqual(0);
    expect(legacyIdx).toBeGreaterThanOrEqual(0);
    expect(xdgIdx).toBeLessThan(legacyIdx);
  });

  it("includes the legacy ~/.agent-orchestrator.yaml dotfile", () => {
    delete process.env.XDG_CONFIG_HOME;
    const paths = getConfigSearchPaths();
    expect(paths).toContain(join(homedir(), ".agent-orchestrator.yaml"));
  });

  it("honours XDG_CONFIG_HOME when computing XDG paths", () => {
    process.env.XDG_CONFIG_HOME = "/tmp/fake-xdg-home";
    const paths = getConfigSearchPaths();
    expect(paths).toContain(
      join("/tmp/fake-xdg-home", "agent-orchestrator", "agent-orchestrator.yaml"),
    );
  });
});
