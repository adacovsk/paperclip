import { mkdtempSync, rmSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { writeBackupLines } from "./backup-lib.js";

describe("writeBackupLines", () => {
  let dir!: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "paperclip-backup-lines-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  async function write(lines: string[], chunkLines?: number) {
    const file = join(dir, "dump.sql");
    await writeBackupLines(file, lines, chunkLines);
    return readFile(file, "utf8");
  }

  // The whole contract: identical bytes to the join it replaces. Every case below
  // straddles a chunk boundary, because that is the only thing the chunking can
  // get wrong — a separator doubled or dropped where two writes meet.
  it.each([
    ["empty", [] as string[], 2],
    ["one line", ["only"], 2],
    ["exactly one chunk", ["a", "b"], 2],
    ["one past a chunk", ["a", "b", "c"], 2],
    ["several whole chunks", ["a", "b", "c", "d"], 2],
    ["chunk size of one", ["a", "b", "c"], 1],
    ["blank lines preserved", ["a", "", "", "b", ""], 2],
    ["chunk larger than input", ["a", "b"], 100],
  ])("matches join for %s", async (_name, lines, chunkLines) => {
    expect(await write(lines, chunkLines)).toBe(lines.join("\n"));
  });

  it("writes no trailing newline", async () => {
    expect(await write(["BEGIN;", "COMMIT;"], 1)).toBe("BEGIN;\nCOMMIT;");
  });

  it("overwrites an existing file rather than appending to it", async () => {
    const file = join(dir, "dump.sql");
    await writeBackupLines(file, ["first run is longer than the second"], 2);
    await writeBackupLines(file, ["short"], 2);
    expect(await readFile(file, "utf8")).toBe("short");
  });

  it("round-trips content that would not survive a single join", async () => {
    // Not the real limit — allocating ~512MB per case would make the suite
    // unrunnable. This pins the behaviour the limit forces: many chunks, lines
    // long enough that the concatenation order actually matters.
    const lines = Array.from({ length: 5_000 }, (_, i) => `INSERT INTO t VALUES (${i}, '${"x".repeat(200)}');`);
    expect(await write(lines, 2_000)).toBe(lines.join("\n"));
  });
});
