import { mkdtemp, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import {
  buildBuilderScaffold,
  buildLaunchBlueprint,
  deriveScenes,
  resolveLaunchVideoPaths,
  type RawReferenceAnalysis,
} from "../../src/lib/launch-video.js";

const rawAnalysis: RawReferenceAnalysis = {
  inputPath: "/tmp/reference.mp4",
  generatedAt: "2026-04-16T00:00:00.000Z",
  durationSeconds: 12,
  width: 1280,
  height: 720,
  nominalFrameRate: 30,
  sampleIntervalSeconds: 2,
  hasAudioTrack: true,
  audioRelativePath: "audio/reference-audio.m4a",
  frames: [
    {
      index: 0,
      timeSeconds: 0,
      timestamp: "00:00.00",
      fileName: "sample-000-00.00s.jpg",
      relativePath: "frames/sample-000-00.00s.jpg",
      averageLuma: 90,
      averageColorHex: "#101010",
      meanPixelDifferenceFromPrevious: 0,
    },
    {
      index: 1,
      timeSeconds: 2,
      timestamp: "00:02.00",
      fileName: "sample-001-02.00s.jpg",
      relativePath: "frames/sample-001-02.00s.jpg",
      averageLuma: 95,
      averageColorHex: "#202020",
      meanPixelDifferenceFromPrevious: 8,
    },
    {
      index: 2,
      timeSeconds: 4,
      timestamp: "00:04.00",
      fileName: "sample-002-04.00s.jpg",
      relativePath: "frames/sample-002-04.00s.jpg",
      averageLuma: 110,
      averageColorHex: "#F0AA00",
      meanPixelDifferenceFromPrevious: 24,
    },
    {
      index: 3,
      timeSeconds: 6,
      timestamp: "00:06.00",
      fileName: "sample-003-06.00s.jpg",
      relativePath: "frames/sample-003-06.00s.jpg",
      averageLuma: 120,
      averageColorHex: "#0A7FFF",
      meanPixelDifferenceFromPrevious: 10,
    },
    {
      index: 4,
      timeSeconds: 8,
      timestamp: "00:08.00",
      fileName: "sample-004-08.00s.jpg",
      relativePath: "frames/sample-004-08.00s.jpg",
      averageLuma: 105,
      averageColorHex: "#FF4A12",
      meanPixelDifferenceFromPrevious: 26,
    },
    {
      index: 5,
      timeSeconds: 10,
      timestamp: "00:10.00",
      fileName: "sample-005-10.00s.jpg",
      relativePath: "frames/sample-005-10.00s.jpg",
      averageLuma: 90,
      averageColorHex: "#111111",
      meanPixelDifferenceFromPrevious: 12,
    },
  ],
};

describe("launch-video helpers", () => {
  it("derives scene boundaries from sampled frame deltas", () => {
    const scenes = deriveScenes(rawAnalysis.frames, rawAnalysis.durationSeconds, 18, 3);

    expect(scenes).toHaveLength(3);
    expect(scenes[0]?.trigger).toBe("opening");
    expect(scenes[1]?.startSeconds).toBe(4);
    expect(scenes[2]?.trigger).toBe("closing");
  });

  it("builds a launch-style blueprint and builder scaffold", async () => {
    const scenes = deriveScenes(rawAnalysis.frames, rawAnalysis.durationSeconds, 18, 3);
    const tempDir = await mkdtemp(join(tmpdir(), "launch-video-test-"));
    const inputPath = join(tempDir, "reference.mp4");
    await writeFile(inputPath, "reference-video");
    const { paths } = await resolveLaunchVideoPaths(
      tempDir,
      inputPath,
      "artifacts/reference-launch-videos",
    );

    const blueprint = buildLaunchBlueprint(rawAnalysis, scenes, "abc123abc123abc123", paths);
    const builder = buildBuilderScaffold(blueprint, paths);

    expect(blueprint.family).toBe("launch-style");
    expect(blueprint.audio.sourceAudioRelativePath).toBe("audio/reference-audio.m4a");
    expect(blueprint.scenes[0]?.editorialRole).toBe("hook");
    expect(blueprint.scenes.at(-1)?.editorialRole).toBe("cta");
    expect(builder.renderStatus).toBe("pending-assets");
    expect(builder.blueprintRelativePath).toBe("blueprints/launch-style-blueprint.json");
  });
});
