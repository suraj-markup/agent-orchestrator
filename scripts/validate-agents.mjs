#!/usr/bin/env node

import { readdir, readFile, stat } from "node:fs/promises";
import { join, relative, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const agentsRoot = join(repoRoot, "agents");

function fail(message) {
  throw new Error(message);
}

async function exists(pathValue) {
  try {
    await stat(pathValue);
    return true;
  } catch {
    return false;
  }
}

async function readJson(pathValue) {
  const raw = await readFile(pathValue, "utf8");
  try {
    return JSON.parse(raw);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    fail(`Invalid JSON in ${relative(repoRoot, pathValue)}: ${message}`);
  }
}

function assertString(value, label) {
  if (typeof value !== "string" || value.trim() === "") {
    fail(`${label} must be a non-empty string`);
  }
}

function assertObject(value, label) {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    fail(`${label} must be an object`);
  }
}

function assertNonEmptyArray(value, label) {
  if (!Array.isArray(value) || value.length === 0) {
    fail(`${label} must be a non-empty array`);
  }
}

function assertNonEmptyStringArray(value, label) {
  assertNonEmptyArray(value, label);
  for (const [index, item] of value.entries()) {
    assertString(item, `${label}[${index}]`);
  }
}

async function listAgentDirs() {
  const entries = await readdir(agentsRoot, { withFileTypes: true });
  return entries
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("_"))
    .map((entry) => join(agentsRoot, entry.name));
}

async function loadAgentRecord(agentDir) {
  const manifestPath = join(agentDir, "agent.json");
  if (!(await exists(manifestPath))) {
    fail(`Missing agent manifest: ${relative(repoRoot, manifestPath)}`);
  }

  const manifest = await readJson(manifestPath);
  return { agentDir, manifest, manifestPath };
}

async function loadSlotRecord(agentDir, slotName, slotRef) {
  const slotDir = resolve(agentDir, slotRef.path);
  const slotManifestPath = join(slotDir, "slot.json");
  if (!(await exists(slotManifestPath))) {
    fail(`Missing slot manifest for ${slotName}: ${relative(repoRoot, slotManifestPath)}`);
  }

  const slotManifest = await readJson(slotManifestPath);
  assertString(slotManifest.slot, `${relative(repoRoot, slotManifestPath)}: slot`);
  assertString(slotManifest.description, `${relative(repoRoot, slotManifestPath)}: description`);
  assertString(slotManifest.configDir, `${relative(repoRoot, slotManifestPath)}: configDir`);
  assertString(slotManifest.sourcesDir, `${relative(repoRoot, slotManifestPath)}: sourcesDir`);
  assertNonEmptyArray(slotManifest.fields, `${relative(repoRoot, slotManifestPath)}: fields`);

  const configDir = resolve(slotDir, slotManifest.configDir);
  const sourcesDir = resolve(slotDir, slotManifest.sourcesDir);

  return { slotDir, slotManifest, slotManifestPath, configDir, sourcesDir };
}

async function assertPromptSourceExists(configPath, configDir, promptSource) {
  const promptSourcePath = resolve(configDir, promptSource);
  if (!(await exists(promptSourcePath))) {
    fail(
      `${relative(repoRoot, configPath)} references missing prompt source ${relative(repoRoot, promptSourcePath)}`,
    );
  }
}

function validateSharedResearchConfig(slotConfig, configPath) {
  assertString(slotConfig.id, `${relative(repoRoot, configPath)}: id`);
  assertString(slotConfig.name, `${relative(repoRoot, configPath)}: name`);
  assertString(slotConfig.promptSource, `${relative(repoRoot, configPath)}: promptSource`);
  assertString(slotConfig.researchMode, `${relative(repoRoot, configPath)}: researchMode`);
  assertString(slotConfig.outputMode, `${relative(repoRoot, configPath)}: outputMode`);
  assertNonEmptyStringArray(slotConfig.sourceTypes, `${relative(repoRoot, configPath)}: sourceTypes`);
  assertNonEmptyStringArray(slotConfig.scoringAxes, `${relative(repoRoot, configPath)}: scoringAxes`);
}

async function validateIdeaGenerationConfig(slotConfig, configPath, configDir) {
  validateSharedResearchConfig(slotConfig, configPath);
  assertString(slotConfig.noveltyBar, `${relative(repoRoot, configPath)}: noveltyBar`);
  await assertPromptSourceExists(configPath, configDir, slotConfig.promptSource);
}

async function validateIdeaValidationConfig(slotConfig, configPath, configDir, agentRecords) {
  validateSharedResearchConfig(slotConfig, configPath);
  assertString(slotConfig.scoreScale, `${relative(repoRoot, configPath)}: scoreScale`);
  assertNonEmptyStringArray(
    slotConfig.researchDimensions,
    `${relative(repoRoot, configPath)}: researchDimensions`,
  );
  assertObject(slotConfig.ideaSource, `${relative(repoRoot, configPath)}: ideaSource`);
  assertString(slotConfig.ideaSource.agentId, `${relative(repoRoot, configPath)}: ideaSource.agentId`);
  assertString(slotConfig.ideaSource.slot, `${relative(repoRoot, configPath)}: ideaSource.slot`);
  assertString(slotConfig.ideaSource.config, `${relative(repoRoot, configPath)}: ideaSource.config`);
  await assertPromptSourceExists(configPath, configDir, slotConfig.promptSource);

  const sourceAgent = agentRecords.get(slotConfig.ideaSource.agentId);
  if (!sourceAgent) {
    fail(
      `${relative(repoRoot, configPath)} references unknown source agent ${slotConfig.ideaSource.agentId}`,
    );
  }

  const sourceSlotRef = sourceAgent.manifest.slots?.[slotConfig.ideaSource.slot];
  assertObject(
    sourceSlotRef,
    `${relative(repoRoot, sourceAgent.manifestPath)}: slots.${slotConfig.ideaSource.slot}`,
  );

  const sourceSlotRecord = await loadSlotRecord(
    sourceAgent.agentDir,
    slotConfig.ideaSource.slot,
    sourceSlotRef,
  );
  const sourceConfigPath = join(sourceSlotRecord.configDir, `${slotConfig.ideaSource.config}.json`);
  if (!(await exists(sourceConfigPath))) {
    fail(
      `${relative(repoRoot, configPath)} references missing source config ${relative(repoRoot, sourceConfigPath)}`,
    );
  }
}

async function validateAgent(agentRecord, agentRecords) {
  const { agentDir, manifest, manifestPath } = agentRecord;
  assertString(manifest.id, `${relative(repoRoot, manifestPath)}: id`);
  assertString(manifest.name, `${relative(repoRoot, manifestPath)}: name`);
  assertString(manifest.description, `${relative(repoRoot, manifestPath)}: description`);
  assertString(manifest.systemPrompt, `${relative(repoRoot, manifestPath)}: systemPrompt`);

  const systemPromptPath = resolve(agentDir, manifest.systemPrompt);
  if (!(await exists(systemPromptPath))) {
    fail(
      `${relative(repoRoot, manifestPath)} references missing system prompt ${relative(repoRoot, systemPromptPath)}`,
    );
  }

  if (typeof manifest.slots !== "object" || manifest.slots === null) {
    fail(`${relative(repoRoot, manifestPath)}: slots must be an object`);
  }

  for (const [slotName, slotRef] of Object.entries(manifest.slots)) {
    assertObject(slotRef, `${relative(repoRoot, manifestPath)}: slots.${slotName}`);

    const slotPathValue = slotRef.path;
    const slotConfigId = slotRef.config;
    assertString(slotPathValue, `${relative(repoRoot, manifestPath)}: slots.${slotName}.path`);
    assertString(slotConfigId, `${relative(repoRoot, manifestPath)}: slots.${slotName}.config`);

    const slotRecord = await loadSlotRecord(agentDir, slotName, slotRef);
    const { configDir, slotManifest } = slotRecord;
    const configPath = join(configDir, `${slotConfigId}.json`);
    if (!(await exists(configPath))) {
      fail(`Missing slot config ${slotConfigId} for ${slotName}: ${relative(repoRoot, configPath)}`);
    }

    const slotConfig = await readJson(configPath);
    switch (slotManifest.slot) {
      case "idea-generation":
        await validateIdeaGenerationConfig(slotConfig, configPath, configDir);
        break;
      case "idea-validation":
        await validateIdeaValidationConfig(slotConfig, configPath, configDir, agentRecords);
        break;
      default:
        fail(
          `Unsupported slot type ${slotManifest.slot} in ${relative(repoRoot, slotRecord.slotManifestPath)}`,
        );
    }
  }
}

async function main() {
  if (!(await exists(agentsRoot))) {
    fail(`Missing agents directory: ${relative(repoRoot, agentsRoot)}`);
  }

  const agentDirs = await listAgentDirs();
  if (agentDirs.length === 0) {
    fail("No repo-local agents found.");
  }

  const agentRecords = new Map();
  for (const agentDir of agentDirs) {
    const agentRecord = await loadAgentRecord(agentDir);
    if (agentRecords.has(agentRecord.manifest.id)) {
      fail(`Duplicate agent id: ${agentRecord.manifest.id}`);
    }
    agentRecords.set(agentRecord.manifest.id, agentRecord);
  }

  for (const agentRecord of agentRecords.values()) {
    await validateAgent(agentRecord, agentRecords);
  }

  console.log(`Validated ${agentRecords.size} repo-local agent definition(s).`);
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(message);
  process.exitCode = 1;
});
