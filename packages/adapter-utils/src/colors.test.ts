import { describe, expect, it } from "vitest";
import { createColors } from "./colors.js";

describe("createColors", () => {
  it("wraps text in the style's codes when enabled", () => {
    const c = createColors(true);
    expect(c.red("x")).toBe("\x1b[31mx\x1b[39m");
    expect(c.bold(1)).toBe("\x1b[1m1\x1b[22m");
  });

  it("returns plain text when disabled", () => {
    const c = createColors(false);
    expect(c.red("x")).toBe("x");
    expect(c.bgCyan(c.black(" tag "))).toBe(" tag ");
  });

  it("reopens the outer style after a nested one closes", () => {
    const c = createColors(true);
    expect(c.red(`a${c.blue("b")}c`)).toBe("\x1b[31ma\x1b[34mb\x1b[31mc\x1b[39m");
    expect(c.bold(`a${c.dim("b")}c`)).toBe("\x1b[1ma\x1b[2mb\x1b[22m\x1b[1mc\x1b[22m");
  });
});
