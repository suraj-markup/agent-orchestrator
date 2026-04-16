import chalk from "chalk";
import type { Command } from "commander";
import { ingestLaunchVideoReference } from "../lib/launch-video.js";
import {
  analyzeReferenceVideo,
  createBuildPlan,
  createRevisionPlan,
  generateBlueprint,
  runJudge,
  summarizeAnalyzeResult,
  summarizeBlueprintResult,
  summarizeBuildResult,
  summarizeJudgeResult,
  summarizeReviseResult,
} from "../lib/launch-video/pipeline.js";

const DEFAULT_INGEST_OUTPUT_ROOT = "artifacts/reference-launch-videos";
const DEFAULT_PIPELINE_OUTPUT_ROOT =
  "/Users/suraj.markupgmail.com/Desktop/video-hackathon-mvp";
const DEFAULT_PROJECT_NAME = "Launch Video MVP";

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
    .option("-o, --output-root <path>", "Artifact root directory", DEFAULT_INGEST_OUTPUT_ROOT)
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

  launchVideo
    .command("analyze")
    .description("Extract and persist analysis outputs for a reference video")
    .requiredOption("-i, --input <path>", "Reference video path")
    .option("-o, --output-root <path>", "Artifact root", DEFAULT_PIPELINE_OUTPUT_ROOT)
    .option("--project-name <name>", "Project name for seeded blueprint", DEFAULT_PROJECT_NAME)
    .option("--force", "Regenerate outputs even when the cache matches")
    .action(
      async (options: {
        input: string;
        outputRoot: string;
        projectName: string;
        force?: boolean;
      }) => {
        const result = await analyzeReferenceVideo({
          inputPath: options.input,
          outputRoot: options.outputRoot,
          projectName: options.projectName,
          force: options.force,
        });
        console.log(summarizeAnalyzeResult(result));
      },
    );

  launchVideo
    .command("blueprint")
    .description("Build blueprint-v1.json from a persisted analysis bundle")
    .option("-i, --input <path>", "Reference video path")
    .option("--artifact-dir <path>", "Existing artifact directory")
    .option("-o, --output-root <path>", "Artifact root", DEFAULT_PIPELINE_OUTPUT_ROOT)
    .option("--assets <path>", "Optional asset override JSON")
    .option("--project-name <name>", "Project name for the blueprint", DEFAULT_PROJECT_NAME)
    .option("--force", "Regenerate blueprint even when it already exists")
    .action(
      async (options: {
        input?: string;
        artifactDir?: string;
        outputRoot: string;
        projectName: string;
        force?: boolean;
      }) => {
        const result = await generateBlueprint({
          inputPath: options.input,
          artifactDir: options.artifactDir,
          outputRoot: options.outputRoot,
          projectName: options.projectName,
          force: options.force,
        });
        console.log(summarizeBlueprintResult(result));
      },
    );

  launchVideo
    .command("build")
    .description("Create a concrete render handoff for the persisted blueprint")
    .option("-i, --input <path>", "Reference video path")
    .option("--artifact-dir <path>", "Existing artifact directory")
    .option("-o, --output-root <path>", "Artifact root", DEFAULT_PIPELINE_OUTPUT_ROOT)
    .option("--project-name <name>", "Project name for the build plan", DEFAULT_PROJECT_NAME)
    .option("--force", "Regenerate the build plan")
    .action(
      async (options: {
        input?: string;
        artifactDir?: string;
        outputRoot: string;
        projectName: string;
        force?: boolean;
      }) => {
        const result = await createBuildPlan({
          inputPath: options.input,
          artifactDir: options.artifactDir,
          outputRoot: options.outputRoot,
          projectName: options.projectName,
          force: options.force,
        });
        console.log(summarizeBuildResult(result));
      },
    );

  launchVideo
    .command("judge")
    .description("Write a structured judge-v1.json review for the current blueprint")
    .option("-i, --input <path>", "Reference video path")
    .option("--artifact-dir <path>", "Existing artifact directory")
    .option("-o, --output-root <path>", "Artifact root", DEFAULT_PIPELINE_OUTPUT_ROOT)
    .option("--project-name <name>", "Project name for judge context", DEFAULT_PROJECT_NAME)
    .option("--force", "Regenerate the judge output")
    .action(
      async (options: {
        input?: string;
        artifactDir?: string;
        outputRoot: string;
        projectName: string;
        force?: boolean;
      }) => {
        const result = await runJudge({
          inputPath: options.input,
          artifactDir: options.artifactDir,
          outputRoot: options.outputRoot,
          projectName: options.projectName,
          force: options.force,
        });
        console.log(summarizeJudgeResult(result));
      },
    );

  launchVideo
    .command("revise")
    .description("Persist the next revision target from judge-v1.json")
    .option("-i, --input <path>", "Reference video path")
    .option("--artifact-dir <path>", "Existing artifact directory")
    .option("-o, --output-root <path>", "Artifact root", DEFAULT_PIPELINE_OUTPUT_ROOT)
    .option("--project-name <name>", "Project name for revision context", DEFAULT_PROJECT_NAME)
    .option("--force", "Regenerate the revision plan")
    .action(
      async (options: {
        input?: string;
        artifactDir?: string;
        outputRoot: string;
        projectName: string;
        force?: boolean;
      }) => {
        const result = await createRevisionPlan({
          inputPath: options.input,
          artifactDir: options.artifactDir,
          outputRoot: options.outputRoot,
          projectName: options.projectName,
          force: options.force,
        });
        console.log(summarizeReviseResult(result));
      },
    );
}
