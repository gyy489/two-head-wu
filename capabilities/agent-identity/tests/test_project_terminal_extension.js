"use strict";

const assert = require("assert");
const path = require("path");
const extension = require(path.join(__dirname, "../vscode/project-terminal-restorer/extension.js"));

const adapterPath = "/private/two-head-wu/agent-identity";
const projectId = "two-head-wu";
const restoredId = "123e4567-e89b-42d3-a456-426614174000";
const existingId = "223e4567-e89b-42d3-a456-426614174000";

function terminal(id, reason) {
  return {
    creationOptions: { env: { TWO_HEAD_WU_PROJECT_TERMINAL_ID: id, TWO_HEAD_WU_PROJECT_ID: projectId } },
    exitStatus: reason === undefined ? undefined : { code: undefined, reason },
    show() {}
  };
}

assert.strictEqual(extension.managedTerminalId(terminal(existingId)), existingId);
assert.strictEqual(extension.managedTerminalId({ creationOptions: {} }), undefined);
assert.deepStrictEqual(extension.missingRestoreEntries([
  { terminal: existingId, auto_restore: true },
  { terminal: restoredId, auto_restore: true },
  { terminal: "323e4567-e89b-42d3-a456-426614174000", auto_restore: false }
], [terminal(existingId)]).map((entry) => entry.terminal), [restoredId]);

const vscode = {
  TerminalExitReason: { Unknown: 0, Shutdown: 1, Process: 2, User: 3, Extension: 4 },
  ThemeIcon: class ThemeIcon { constructor(id) { this.id = id; } },
  workspace: {
    workspaceFolders: [{ name: "两头乌", uri: { fsPath: "/workspace/two-head-wu" } }],
    getConfiguration() {
      return {
        get(key, fallback) {
          return ({ enabled: true, projectId, adapterPath, autoReveal: true })[key] ?? fallback;
        }
      };
    }
  },
  commands: {
    handlers: {},
    registerCommand(name, handler) {
      this.handlers[name] = handler;
      return { dispose() {} };
    }
  },
  window: {
    terminals: [terminal(existingId)],
    created: [],
    closeHandler: undefined,
    warnings: [],
    createTerminal(options) {
      const value = { creationOptions: options, exitStatus: undefined, show() {} };
      this.created.push(value);
      this.terminals.push(value);
      return value;
    },
    onDidCloseTerminal(handler) {
      this.closeHandler = handler;
      return { dispose() {} };
    },
    showWarningMessage(message) { this.warnings.push(message); },
    async showQuickPick(items) { return items[0]; }
  }
};

const calls = [];
async function runJson(_adapter, args) {
  calls.push(args);
  if (args[0] === "status") {
    return { identities: [{ id: "owner-primary", state_kind: "default", selection_mode: "project-auto", usage_scope: "owner-local" }] };
  }
  if (args[1] === "allocate") {
    return { terminal: "323e4567-e89b-42d3-a456-426614174000", project: projectId, cwd: "/workspace/two-head-wu" };
  }
  if (args[1] === "list") {
    return {
      restore: [
        { terminal: existingId, project: projectId, thread: "a", cwd: "/workspace/two-head-wu", auto_restore: true, name: "existing" },
        { terminal: restoredId, project: projectId, thread: "b", cwd: "/workspace/two-head-wu", auto_restore: true, name: "restore me" }
      ]
    };
  }
  return { result: "ok" };
}

(async () => {
  const context = { subscriptions: [] };
  const activated = extension.activateWith(vscode, context, { runJson, report: (message) => vscode.window.warnings.push(message) });
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(vscode.window.created.length, 1, "startup should create only the missing recovery terminal");
  const options = vscode.window.created[0].creationOptions;
  assert.strictEqual(options.shellPath, adapterPath);
  assert.deepStrictEqual(options.shellArgs, ["project-terminal", "restore", "--terminal", restoredId]);
  assert.strictEqual(options.env.TWO_HEAD_WU_TERMINAL_INSTANCE_ID, restoredId);

  await activated.restoreAll(true);
  assert.strictEqual(vscode.window.created.length, 1, "second reconciliation must not duplicate a terminal");

  vscode.window.closeHandler(terminal(restoredId, vscode.TerminalExitReason.Shutdown));
  assert.strictEqual(calls.filter((args) => args[1] === "close").length, 0, "shutdown must preserve recovery state");
  vscode.window.closeHandler(terminal(restoredId, vscode.TerminalExitReason.User));
  await new Promise((resolve) => setImmediate(resolve));
  const closeCalls = calls.filter((args) => args[1] === "close");
  assert.strictEqual(closeCalls.length, 1, "user close must suppress recovery");
  assert(closeCalls[0].includes("--reason") && closeCalls[0].includes("user"));

  await vscode.commands.handlers["twoHeadWu.projectTerminals.openNew"]();
  const newTerminal = vscode.window.created[1].creationOptions;
  assert.deepStrictEqual(newTerminal.shellArgs, [
    "project-terminal", "start", "--terminal", "323e4567-e89b-42d3-a456-426614174000", "--alias", "owner-primary"
  ]);
  assert.strictEqual(vscode.window.warnings.length, 0);
  console.log("project terminal extension tests ok");
})().catch((error) => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
