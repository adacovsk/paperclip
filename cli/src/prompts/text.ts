import * as p from "@clack/prompts";

type TextOptions = Parameters<typeof p.text>[0];

export type PromptTextOptions = Omit<TextOptions, "validate"> & {
  validate?: (value: string) => string | Error | undefined;
};

/**
 * `p.text` with validation of the value the prompt will return.
 *
 * clack runs `validate` on the raw input and substitutes `defaultValue` only
 * after it passes, so an empty Enter reached each validator as "" (0.x) or
 * `undefined` (1.x). A validator that requires a value then refused the very
 * default the prompt was offering, and under 1.x `val.trim()` threw instead.
 * An empty input is validated as the default it will become.
 */
export function promptText(opts: PromptTextOptions): ReturnType<typeof p.text> {
  const { validate, ...rest } = opts;
  if (!validate) return p.text(rest);
  return p.text({
    ...rest,
    validate: (value) => validate(value ? value : (opts.defaultValue ?? "")),
  });
}
