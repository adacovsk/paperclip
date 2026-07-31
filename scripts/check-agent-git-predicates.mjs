#!/usr/bin/env node
/**
 * check-agent-git-predicates.mjs
 *
 * Guards agent INSTRUCTIONS.md against git predicates that silently always
 * report "false" — the failure mode that makes an audit step look like it ran
 * and found nothing.
 *
 * The one that shipped: `git branch --contains <sha> origin/main`. It reads as
 * "is <sha> on origin/main", but `--contains` filters the *branch list* and the
 * trailing argument is a shell-glob pattern over **local** branch names. A
 * remote-tracking ref never matches one, so the command returns empty for every
 * SHA — including commits demonstrably on main. Coordinator's PR-evidence audit
 * used it as its accept/re-open predicate and therefore re-opened everything.
 *
 * Use `git merge-base --is-ancestor <sha> origin/main` instead and branch on the
 * exit code (0 = on main). To check remote branches by name, `git branch -r
 * --contains <sha>` is the correct spelling.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)));
const AGENTS_DIR = join(REPO_ROOT, "agents");

/**
 * `git branch --contains <rev> <remote-ish-pattern>` with no `-r`/`-a`.
 * Matching the remote-looking trailing pattern is what distinguishes the broken
 * predicate from a legitimate `git branch --contains <sha>` (no pattern) or an
 * explicitly remote `git branch -r --contains <sha>`.
 */
const BROKEN_PREDICATES = [
  {
    pattern: /git\s+(?:-C\s+\S+\s+)?branch\s+(?!-r\b|-a\b)--contains\s+\S+\s+(?:origin|upstream)\//,
    reason:
      "`git branch --contains <sha> origin/...` always returns empty — the trailing arg is a glob over LOCAL branch names. Use `git merge-base --is-ancestor <sha> origin/main` (exit 0 = on main), or `git branch -r --contains <sha>` to list remote branches.",
  },
];

function markdownFilesUnder(dir) {
  const found = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) found.push(...markdownFilesUnder(full));
    else if (entry.endsWith(".md")) found.push(full);
  }
  return found;
}

export function findBrokenPredicates(text, file) {
  const violations = [];
  text.split("\n").forEach((line, index) => {
    for (const { pattern, reason } of BROKEN_PREDICATES) {
      if (pattern.test(line)) {
        violations.push({ file, line: index + 1, text: line.trim(), reason });
      }
    }
  });
  return violations;
}

function main() {
  let files;
  try {
    files = markdownFilesUnder(AGENTS_DIR);
  } catch {
    console.log("check:agent-git — no agents/ directory, nothing to check.");
    return;
  }

  const violations = files.flatMap((file) =>
    findBrokenPredicates(readFileSync(file, "utf8"), file),
  );

  if (violations.length === 0) {
    console.log(`check:agent-git — ${files.length} agent doc(s) clean.`);
    return;
  }

  for (const violation of violations) {
    console.error(`\n${relative(REPO_ROOT, violation.file)}:${violation.line}`);
    console.error(`  ${violation.text}`);
    console.error(`  → ${violation.reason}`);
  }
  console.error(`\n${violations.length} broken git predicate(s) found.`);
  process.exit(1);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
