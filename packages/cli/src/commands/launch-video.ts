import chalk from "chalk";
import type { Command } from "commander";
import { ingestLaunchVideoReference } from "../lib/launch-video.js";

export function registerLaunchVideo(program: Command): void {
  const launchVideo = program
    .command("launch-video")
    .description("Reference-driven launch-style video MVP helpers");

  launchVideo
    .command("ingest")
    .description(
      "Analyze a reference video, persist reusable artifacts, and generate a launch blueprint",
    )
    .argument("<input>", "Path to the reference video")
    .option(
      "-o, --output-root <path>",
      "Artifact root directory",
      "artifacts/reference-launch-videos",
    )
    .option("--sample-interval <seconds>", "Seconds between sampled frames", "2")
    .option(
      "--scene-threshold <delta>",
      "Scene-cut threshold derived from sampled frame delta",
      "18",
    )
    .option("--min-scene-length <seconds>", "Minimum seconds between scene boundaries", "4")
    .option("--force", "Re-run extraction even if persisted analysis exists")
    .action(
      async (
        input: string,
        opts: {
          outputRoot: string;
          sampleInterval: string;
          sceneThreshold: string;
          minSceneLength: string;
          force?: boolean;
        },
      ) => {
        const result = await ingestLaunchVideoReference({
          inputPath: input,
          cwd: process.cwd(),
          outputRoot: opts.outputRoot,
          sampleIntervalSeconds: Number(opts.sampleInterval),
          sceneThreshold: Number(opts.sceneThreshold),
          minSceneLengthSeconds: Number(opts.minSceneLength),
          force: opts.force === true,
        });

        console.log(
          chalk.bold(
            `${result.reusedAnalysis ? "Reused" : "Generated"} reference artifacts at ${result.artifactRoot}`,
          ),
        );
        console.log(`Scenes: ${result.sceneCount}`);
        console.log(`Keyframes: ${result.keyframeCount}`);
        console.log(`Blueprint: ${result.blueprintPath}`);
        console.log(`Builder scaffold: ${result.builderPath}`);
        console.log(`Transcript placeholder: ${result.transcriptPath}`);
        console.log(`Notes: ${result.notesPath}`);
      },
    );
}
