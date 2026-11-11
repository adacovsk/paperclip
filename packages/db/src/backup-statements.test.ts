import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { readBackupStatements, STATEMENT_BREAKPOINT as BP } from "./backup-lib.js";

describe("readBackupStatements", () => {
  let dir!: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "paperclip-backup-statements-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  async function read(contents: string, chunkBytes: number) {
    const file = join(dir, "dump.sql");
    writeFileSync(file, contents, "utf8");
    const out: string[] = [];
    for await (const statement of readBackupStatements(file, chunkBytes)) out.push(statement);
    return out;
  }

  // The contract is the in-memory split it replaces, at every chunk size: a
  // small chunk is what puts a breakpoint, or a multi-byte character, across
  // two reads.
  const cases: Array<[string, string]> = [
    ["empty", ""],
    ["no breakpoint", "SELECT 1;"],
    ["typical", `BEGIN;\n${BP}\nCREATE TABLE "t" ("a" text);\n${BP}\nINSERT INTO "t" VALUES ('x');\n${BP}\nCOMMIT;`],
    ["adjacent breakpoints", `a${BP}${BP}b`],
    ["leading and trailing breakpoint", `${BP}\nmiddle\n${BP}`],
    ["CRLF inside data", `INSERT INTO "t" VALUES (E'line1\\r\\nline2');\r\n${BP}\r\nSELECT 2;`],
    ["multi-byte characters", `INSERT INTO "t" VALUES ('héllo — 世界 🚀');\n${BP}\nSELECT 'ü';`],
  ];

  for (const [name, contents] of cases) {
    it(`matches split() for ${name} at every chunk size`, async () => {
      const expected = contents.split(BP);
      const sizes = new Set([1, 2, 3, 7, BP.length - 1, BP.length, BP.length + 1, Buffer.byteLength(contents) + 1]);
      for (const size of sizes) {
        expect(await read(contents, size)).toEqual(expected);
      }
    });
  }
});
