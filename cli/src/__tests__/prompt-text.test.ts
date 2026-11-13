import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import { promptText, type PromptTextOptions } from "../prompts/text.js";

function terminal() {
  const input = Object.assign(new PassThrough(), { isTTY: true, setRawMode: () => {} });
  const output = Object.assign(new PassThrough(), { isTTY: true, columns: 80 });
  output.on("data", () => {});
  return { input, output };
}

async function answer(keys: string[], opts: PromptTextOptions) {
  const { input, output } = terminal();
  const seen: string[] = [];
  const pending = promptText({
    ...opts,
    input,
    output,
    validate: (value) => {
      seen.push(value);
      return opts.validate?.(value);
    },
  });
  for (const key of keys) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    input.write(key);
  }
  const result = await Promise.race([
    pending,
    new Promise((resolve) => setTimeout(() => resolve("<still prompting>"), 500)),
  ]);
  return { result, seen };
}

const required = (value: string) => (value.trim() ? undefined : "required");

describe("promptText", () => {
  it("accepts the default on an empty Enter, validating the default", async () => {
    const { result, seen } = await answer(["\r"], {
      message: "Bind host",
      defaultValue: "127.0.0.1",
      validate: required,
    });
    expect(seen).toEqual(["127.0.0.1"]);
    expect(result).toBe("127.0.0.1");
  });

  it("validates typed input as typed", async () => {
    const { result, seen } = await answer(["a", "b", "\r"], {
      message: "Bind host",
      defaultValue: "127.0.0.1",
      validate: required,
    });
    expect(seen).toEqual(["ab"]);
    expect(result).toBe("ab");
  });

  it("still refuses an empty Enter when there is no default", async () => {
    const { result, seen } = await answer(["\r"], { message: "Bind host", validate: required });
    expect(seen).toEqual([""]);
    expect(result).toBe("<still prompting>");
  });
});
