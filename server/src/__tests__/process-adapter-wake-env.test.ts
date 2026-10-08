import { describe, expect, it } from "vitest";
import { execute } from "../adapters/process/execute.js";

// A process agent acts on the API as itself, so it needs the wake context and the
// run-scoped token a CLI agent gets; without them its writes land as the operator's.
describe("process adapter wake env", () => {
  it("passes the wake task, reason, run id and token to the command", async () => {
    const result = await execute({
      runId: "run-1",
      agent: { id: "agent-1", companyId: "company-1", name: "Advancer", adapterType: "process", adapterConfig: {} },
      runtime: { sessionId: null, sessionParams: null, sessionDisplayId: null, taskKey: null },
      config: {
        command: "sh",
        args: ["-c", 'printf "%s|%s|%s|%s" "$PAPERCLIP_TASK_ID" "$PAPERCLIP_WAKE_REASON" "$PAPERCLIP_RUN_ID" "$PAPERCLIP_API_KEY"'],
      },
      context: { issueId: "issue-1", wakeReason: "subtask_completed" },
      onLog: async () => {},
      authToken: "token-1",
    } as any);
    expect(result.exitCode).toBe(0);
    expect((result.resultJson as { stdout: string }).stdout).toBe("issue-1|subtask_completed|run-1|token-1");
  });

  it("leaves wake vars unset when the wake carries none", async () => {
    const result = await execute({
      runId: "run-2",
      agent: { id: "agent-1", companyId: "company-1", name: "Advancer", adapterType: "process", adapterConfig: {} },
      runtime: { sessionId: null, sessionParams: null, sessionDisplayId: null, taskKey: null },
      config: { command: "sh", args: ["-c", 'printf "%s" "${PAPERCLIP_TASK_ID-unset}"'] },
      context: {},
      onLog: async () => {},
    } as any);
    expect((result.resultJson as { stdout: string }).stdout).toBe("unset");
  });
});
