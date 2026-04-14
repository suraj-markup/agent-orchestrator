import { describe, it, expect, afterEach } from "vitest";
import { apiPath } from "../api-path";

const ORIGINAL_BASE = process.env.NEXT_PUBLIC_BASE_PATH;

afterEach(() => {
  if (ORIGINAL_BASE === undefined) {
    delete process.env.NEXT_PUBLIC_BASE_PATH;
  } else {
    process.env.NEXT_PUBLIC_BASE_PATH = ORIGINAL_BASE;
  }
});

describe("apiPath", () => {
  it("returns the path unchanged when NEXT_PUBLIC_BASE_PATH is unset", () => {
    delete process.env.NEXT_PUBLIC_BASE_PATH;
    expect(apiPath("/api/sessions")).toBe("/api/sessions");
  });

  it("returns the path unchanged when NEXT_PUBLIC_BASE_PATH is empty", () => {
    process.env.NEXT_PUBLIC_BASE_PATH = "";
    expect(apiPath("/api/sessions")).toBe("/api/sessions");
  });

  it("prepends the base path to a leading-slash path", () => {
    process.env.NEXT_PUBLIC_BASE_PATH = "/terminal";
    expect(apiPath("/api/sessions/abc")).toBe("/terminal/api/sessions/abc");
  });

  it("prepends the base path to a relative path", () => {
    process.env.NEXT_PUBLIC_BASE_PATH = "/terminal";
    expect(apiPath("api/sessions")).toBe("/terminal/api/sessions");
  });

  it("strips trailing slashes from the base path before concatenating", () => {
    process.env.NEXT_PUBLIC_BASE_PATH = "/terminal/";
    expect(apiPath("/api/sessions")).toBe("/terminal/api/sessions");
  });

  it("handles nested base paths", () => {
    process.env.NEXT_PUBLIC_BASE_PATH = "/tools/ao";
    expect(apiPath("/api/events?project=x")).toBe("/tools/ao/api/events?project=x");
  });
});
