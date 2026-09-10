"use strict";

const childProcess = require("child_process");
const path = require("path");
const util = require("util");

const execFile = util.promisify(childProcess.execFile);
const PROJECT_ENV = "TWO_HEAD_WU_PROJECT_ID";
const TERMINAL_ENV = "TWO_HEAD_WU_PROJECT_TERMINAL_ID";
const INSTANCE_ENV = "TWO_HEAD_WU_TERMINAL_INSTANCE_ID";
const CONFIG_SECTION = "twoHeadWu.projectTerminals";
const PROJECT_PATTERN = /^[a-z][a-z0-9-]{0,62}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function managedTerminalId(terminal) {
  const options = terminal && terminal.creationOptions;
  const env = options && options.env;
  const value = env && env[TERMINAL_ENV];
  return typeof value === "string" && UUID_PATTERN.test(value) ? value.toLowerCase() : undefined;
}

function missingRestoreEntries(entries, terminals) {
  const existing = new Set((terminals || []).map(managedTerminalId).filter(Boolean));
  return (entries || []).filter((entry) => entry && entry.auto_restore === true && UUID_PATTERN.test(entry.terminal) && !existing.has(entry.terminal.toLowerCase()));
}

function terminalOptions(entry, adapterPath, vscode, mode = "restore", alias) {
  const terminalId = entry.terminal.toLowerCase();
  const shellArgs = ["project-terminal", mode, "--terminal", terminalId];
  if (mode === "start") {
    shellArgs.push("--alias", alias);
  }
  return {
    name: entry.name || `Codex ${String(entry.thread || terminalId).slice(0, 8)}`,
    shellPath: adapterPath,
    shellArgs,
    cwd: entry.cwd,
    env: {
      [PROJECT_ENV]: entry.project,
      [TERMINAL_ENV]: terminalId,
      [INSTANCE_ENV]: terminalId
    },
    iconPath: vscode && vscode.ThemeIcon ? new vscode.ThemeIcon("terminal") : undefined,
    isTransient: false
  };
}

function shouldCloseRegistry(reason, vscode) {
  return reason === vscode.TerminalExitReason.User || reason === vscode.TerminalExitReason.Extension;
}

async function defaultRunJson(adapterPath, args) {
  if (!path.isAbsolute(adapterPath)) {
    throw new Error("agent-identity adapterPath must be absolute");
  }
  const result = await execFile(adapterPath, args, {
    encoding: "utf8",
    timeout: 15000,
    maxBuffer: 1024 * 1024
  });
  return JSON.parse(result.stdout);
}

function folderConfiguration(vscode, folder) {
  const config = vscode.workspace.getConfiguration(CONFIG_SECTION, folder.uri);
  const enabled = config.get("enabled", false);
  const projectId = config.get("projectId", "");
  const adapterPath = config.get("adapterPath", "");
  const autoReveal = config.get("autoReveal", true);
  if (!enabled) {
    return undefined;
  }
  if (!PROJECT_PATTERN.test(projectId)) {
    throw new Error(`invalid projectId for ${folder.name}`);
  }
  if (!path.isAbsolute(adapterPath)) {
    throw new Error(`adapterPath must be absolute for ${folder.name}`);
  }
  return { projectId, adapterPath, autoReveal };
}

function configuredFolders(vscode) {
  const folders = vscode.workspace.workspaceFolders || [];
  const result = [];
  for (const folder of folders) {
    const configuration = folderConfiguration(vscode, folder);
    if (configuration) {
      result.push({ folder, configuration });
    }
  }
  return result;
}

function boundedError(error) {
  const text = error && error.message ? error.message : String(error);
  return text.replace(/[\r\n]+/g, " ").slice(0, 400);
}

async function restoreFolder(vscode, folder, configuration, runJson, reveal) {
  const payload = await runJson(configuration.adapterPath, [
    "project-terminal", "list", "--project", configuration.projectId, "--json"
  ]);
  const missing = missingRestoreEntries(payload.restore, vscode.window.terminals);
  const created = missing.map((entry) => vscode.window.createTerminal(terminalOptions(entry, configuration.adapterPath, vscode)));
  if (reveal && configuration.autoReveal && created.length > 0) {
    created[0].show(true);
  }
  return created;
}

async function selectConfiguredFolder(vscode) {
  const items = configuredFolders(vscode);
  if (items.length === 0) {
    throw new Error("this workspace has no enabled Two-Headed-Wu project terminal configuration");
  }
  if (items.length === 1) {
    return items[0];
  }
  const picked = await vscode.window.showQuickPick(items.map((item) => ({
    label: item.folder.name,
    description: item.configuration.projectId,
    item
  })), { placeHolder: "Select a managed project" });
  return picked && picked.item;
}

async function openNewManagedTerminal(vscode, runJson) {
  const selected = await selectConfiguredFolder(vscode);
  if (!selected) {
    return undefined;
  }
  const { folder, configuration } = selected;
  const status = await runJson(configuration.adapterPath, ["status", "--json"]);
  const identities = (status.identities || []).filter((identity) => identity.usage_scope === "owner-local");
  const picked = await vscode.window.showQuickPick(identities.map((identity) => ({
    label: identity.id,
    description: `${identity.state_kind} · ${identity.selection_mode}`,
    identity
  })), { placeHolder: "Select the Codex identity for the new terminal" });
  if (!picked) {
    return undefined;
  }
  const allocated = await runJson(configuration.adapterPath, [
    "project-terminal", "allocate", "--project", configuration.projectId,
    "--cwd", folder.uri.fsPath, "--json"
  ]);
  const terminal = vscode.window.createTerminal(terminalOptions(allocated, configuration.adapterPath, vscode, "start", picked.identity.id));
  terminal.show(false);
  return terminal;
}

function activateWith(vscode, context, dependencies = {}) {
  const runJson = dependencies.runJson || defaultRunJson;
  const report = dependencies.report || ((message) => vscode.window.showWarningMessage(message));

  const restoreAll = async (reveal = true) => {
    const created = [];
    for (const { folder, configuration } of configuredFolders(vscode)) {
      try {
        created.push(...await restoreFolder(vscode, folder, configuration, runJson, reveal));
      } catch (error) {
        report(`Two-Headed-Wu terminal restore paused: ${boundedError(error)}`);
      }
    }
    return created;
  };

  context.subscriptions.push(vscode.commands.registerCommand("twoHeadWu.projectTerminals.restoreNow", () => restoreAll(true)));
  context.subscriptions.push(vscode.commands.registerCommand("twoHeadWu.projectTerminals.openNew", async () => {
    try {
      return await openNewManagedTerminal(vscode, runJson);
    } catch (error) {
      report(`Two-Headed-Wu managed terminal could not open: ${boundedError(error)}`);
      return undefined;
    }
  }));
  context.subscriptions.push(vscode.window.onDidCloseTerminal((terminal) => {
    const terminalId = managedTerminalId(terminal);
    const reason = terminal.exitStatus && terminal.exitStatus.reason;
    if (!terminalId || !shouldCloseRegistry(reason, vscode)) {
      return;
    }
    const options = terminal.creationOptions || {};
    const env = options.env || {};
    const projectId = env[PROJECT_ENV];
    const match = configuredFolders(vscode).find((item) => item.configuration.projectId === projectId);
    if (!match) {
      return;
    }
    const closeReason = reason === vscode.TerminalExitReason.Extension ? "extension" : "user";
    runJson(match.configuration.adapterPath, [
      "project-terminal", "close", "--terminal", terminalId, "--reason", closeReason, "--json"
    ]).catch((error) => report(`Two-Headed-Wu terminal close state was not saved: ${boundedError(error)}`));
  }));

  Promise.resolve().then(() => restoreAll(true));
  return { restoreAll };
}

function activate(context) {
  return activateWith(require("vscode"), context);
}

function deactivate() {}

module.exports = {
  activate,
  deactivate,
  activateWith,
  managedTerminalId,
  missingRestoreEntries,
  terminalOptions,
  shouldCloseRegistry,
  boundedError
};
