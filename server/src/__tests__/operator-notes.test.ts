import { describe, expect, it } from "vitest";
import { OPERATOR_NOTES_MAX, OPERATOR_NOTE_MAX_CHARS, renderOperatorNotes } from "../services/operator-notes.js";

const op = (body: string, createdAt: string) => ({ authorUserId: "local-operator", body, createdAt });
const agent = (body: string, createdAt: string) => ({ authorUserId: null, body, createdAt });

describe("renderOperatorNotes", () => {
  it("is empty when no person commented", () => {
    expect(renderOperatorNotes([])).toBe("");
    expect(renderOperatorNotes([agent("Worker verdict: no-op", "2026-01-01T00:00:00Z")])).toBe("");
  });

  it("carries only operator comments, newest first", () => {
    const out = renderOperatorNotes([
      op("first ruling", "2026-01-01T00:00:00Z"),
      agent("re-dispatch: no new commits", "2026-01-02T00:00:00Z"),
      op("second ruling", "2026-01-03T00:00:00Z"),
    ]);
    expect(out).toContain("## Operator notes on this task (newest first)");
    expect(out).not.toContain("re-dispatch");
    expect(out.indexOf("second ruling")).toBeLessThan(out.indexOf("first ruling"));
  });

  it("keeps the newest few and clips a long note at its head", () => {
    const many = Array.from({ length: OPERATOR_NOTES_MAX + 2 }, (_, n) =>
      op(`note ${n}`, `2026-01-0${n + 1}T00:00:00Z`));
    const out = renderOperatorNotes(many);
    expect(out).toContain(`note ${OPERATOR_NOTES_MAX + 1}`);
    expect(out).not.toContain("note 0");

    const long = renderOperatorNotes([op(`do this ${"x".repeat(OPERATOR_NOTE_MAX_CHARS)}`, "2026-01-01T00:00:00Z")]);
    expect(long).toContain("do this");
    expect(long).toContain("[truncated]");
  });

  it("skips blank comments", () => {
    expect(renderOperatorNotes([op("   ", "2026-01-01T00:00:00Z")])).toBe("");
  });
});
