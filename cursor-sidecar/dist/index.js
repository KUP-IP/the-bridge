#!/usr/bin/env node
import readline from "node:readline";

const runs = new Map();
const artifacts = new Map();

function write(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function ok(id, result) {
  write({ jsonrpc: "2.0", id, result });
}

function fail(id, code, message, data) {
  write({ jsonrpc: "2.0", id, error: { code, message, data } });
}

async function loadSdk() {
  try {
    return await import("@cursor/sdk");
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    const wrapped = new Error(`@cursor/sdk unavailable: ${reason}`);
    wrapped.code = 10002;
    throw wrapped;
  }
}

function modelSelection(model) {
  return model ? { id: model } : undefined;
}

function sdkStatus(status) {
  switch (status) {
    case "finished":
      return "succeeded";
    case "error":
      return "failed";
    case "cancelled":
      return "cancelled";
    case "running":
      return "running";
    default:
      return "unknown";
  }
}

function runToBridge(run, meta = {}) {
  const startedAt = run.createdAt ? new Date(run.createdAt).toISOString() : meta.startedAt ?? new Date().toISOString();
  const git = run.git?.branches?.[0];
  return {
    id: run.id,
    runtime: meta.runtime ?? "local",
    model: typeof run.model === "string" ? run.model : run.model?.id ?? meta.model ?? "cursor-default",
    status: sdkStatus(run.status),
    startedAt,
    endedAt: ["finished", "error", "cancelled"].includes(run.status) ? new Date().toISOString() : null,
    costCents: meta.costCents ?? null,
    repoPath: meta.repoPath ?? null,
    prURL: git?.prUrl ?? null,
    lastEventId: meta.lastEventId ?? null
  };
}

async function handle(method, params = {}) {
  switch (method) {
    case "ping":
      return { pong: "true", sidecar: "cursor-sidecar" };
    case "capability_probe": {
      await loadSdk();
      return {
        ok: "true",
        sdk: "@cursor/sdk",
        version: "1.0.13",
        hasApiKey: process.env.CURSOR_API_KEY ? "true" : "false"
      };
    }
    case "agent_run": {
      const { Agent } = await loadSdk();
      const runtime = params.runtime ?? "local";
      const model = modelSelection(params.model);
      const options = {
        apiKey: process.env.CURSOR_API_KEY,
        model,
        name: "NotionBridge Cursor Agent"
      };
      if (runtime === "local") {
        if (!params.repoPath) {
          const error = new Error("repoPath is required for local runtime");
          error.code = 10002;
          throw error;
        }
        options.local = { cwd: params.repoPath };
      } else {
        options.cloud = { autoCreatePR: true };
        if (params.branch) {
          options.cloud.workOnCurrentBranch = false;
        }
      }
      const agent = await Agent.create(options);
      const run = await agent.send(params.prompt, model ? { model } : undefined);
      const meta = {
        runtime,
        model: params.model ?? "cursor-default",
        repoPath: params.repoPath ?? null,
        startedAt: new Date().toISOString()
      };
      runs.set(run.id, { run, agent, meta });
      artifacts.set(run.id, []);
      run.wait().then((result) => {
        const current = runs.get(run.id);
        if (current) {
          current.result = result;
        }
      }).catch((error) => {
        const current = runs.get(run.id);
        if (current) {
          current.error = error instanceof Error ? error.message : String(error);
        }
      });
      return runToBridge(run, meta);
    }
    case "agent_status": {
      const entry = runs.get(params.id);
      if (!entry) {
        const error = new Error(`unknown run id: ${params.id}`);
        error.code = 10004;
        throw error;
      }
      return runToBridge(entry.run, entry.meta);
    }
    case "agent_list":
      return {
        runs: Array.from(runs.values())
          .map((entry) => runToBridge(entry.run, entry.meta))
          .filter((run) => !params.status || run.status === params.status)
          .filter((run) => !params.runtime || run.runtime === params.runtime)
      };
    case "agent_cancel": {
      const entry = runs.get(params.id);
      if (!entry) {
        const error = new Error(`unknown run id: ${params.id}`);
        error.code = 10004;
        throw error;
      }
      await entry.run.cancel();
      return runToBridge(entry.run, entry.meta);
    }
    case "agent_artifacts": {
      const entry = runs.get(params.id);
      if (!entry) {
        const error = new Error(`unknown run id: ${params.id}`);
        error.code = 10004;
        throw error;
      }
      const listed = await entry.agent.listArtifacts().catch(() => []);
      return {
        artifacts: listed.map((artifact) => ({
          kind: artifact.kind ?? "file",
          url: artifact.url ?? artifact.path ?? null,
          label: artifact.label ?? artifact.name ?? null,
          mediaType: artifact.mediaType ?? null
        }))
      };
    }
    default: {
      const error = new Error(`unknown method: ${method}`);
      error.code = -32601;
      throw error;
    }
  }
}

readline.createInterface({ input: process.stdin, crlfDelay: Infinity }).on("line", async (line) => {
  if (!line.trim()) return;
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  try {
    const result = await handle(message.method, message.params);
    ok(message.id, result);
  } catch (error) {
    fail(
      message.id,
      Number.isInteger(error?.code) ? error.code : 10004,
      error instanceof Error ? error.message : String(error)
    );
  }
});
