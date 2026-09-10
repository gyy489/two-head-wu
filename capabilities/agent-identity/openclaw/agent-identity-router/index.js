import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const ADAPTER = "capabilities/agent-identity/adapters/agent-identity";
const CHANNEL = "openclaw-weixin";
const ALIASES = ["owner-primary", "owner-secondary", "member-one", "member-two", "member-three"];
const UTF8_ENV = {
  ...process.env,
  LANG: process.env.LANG || "en_US.UTF-8",
  LC_ALL: process.env.LC_ALL || "en_US.UTF-8"
};

function unique(values) {
  const seen = new Set();
  const result = [];
  for (const value of values) {
    if (typeof value !== "string") continue;
    const trimmed = value.trim();
    if (!trimmed || seen.has(trimmed)) continue;
    seen.add(trimmed);
    result.push(trimmed);
  }
  return result;
}

function sessionCandidatesFromContext(ctx) {
  const candidates = [
    ctx.from,
    ctx.senderId,
    ctx.to,
    ctx.messageThreadId?.toString(),
    ctx.threadParentId?.toString(),
    ctx.sessionId,
    ctx.sessionKey
  ];
  return unique(candidates);
}

function formatError(error) {
  const message = error?.stderr?.trim() || error?.message || String(error);
  return message.replaceAll(ADAPTER, "agent-identity").slice(0, 240);
}

async function switchIdentity(ctx, alias) {
  if (ctx.channel !== CHANNEL) {
    return { text: "这个命令只在微信通道生效。", isError: true };
  }

  const sessions = sessionCandidatesFromContext(ctx);
  if (sessions.length === 0) {
    return { text: "无法识别当前微信会话，未切换账号。", isError: true };
  }

  let lastError;
  for (const session of sessions) {
    try {
      await execFileAsync(
        ADAPTER,
        [
          "route-command",
          "--channel",
          CHANNEL,
          "--session",
          session,
          "--text",
          `/${alias}`,
          "--json"
        ],
        { env: UTF8_ENV }
      );
      return { text: `已切换到 ${alias}。发送 /new 后，新对话会按这个身份路由。` };
    } catch (error) {
      lastError = error;
    }
  }

  return { text: `切换到 ${alias} 失败：${formatError(lastError)}`, isError: true };
}

export default definePluginEntry({
  id: "agent-identity-router",
  name: "Agent Identity Router",
  description: "Owner-only WeChat identity route commands.",
  register(api) {
    for (const alias of ALIASES) {
      api.registerCommand({
        name: alias,
        description: `Switch this WeChat session to ${alias}.`,
        acceptsArgs: false,
        exposeSenderIsOwner: true,
        channels: [CHANNEL],
        handler: async (ctx) => switchIdentity(ctx, alias)
      });
    }
  }
});
