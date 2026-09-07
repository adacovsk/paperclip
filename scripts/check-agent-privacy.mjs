#!/usr/bin/env node
// Keeps the private downstream project out of this public repo.
//
// WHY. `agents/**` configures this instance against a PRIVATE repo, but paperclip
// is PUBLIC and ships `agents/` in the npm package (no `files` field, no
// `.npmignore`), so anything written there is published, not merely pushed.
//
// Every rule in those docs was bought with a real incident, and writing the
// incident down is what stops the rule being re-litigated. So the narration
// stays. What must not stay is anything identifying the private project.
// Keep the lesson, drop the pointer.
//
// WHY THIS IS STRUCTURAL AND NOT A LIST OF NAMES. The first version of this
// guard held a `PRIVATE_TERMS` array of the private module names. That is
// self-defeating twice over:
//
//   1. It publishes, in a public file, the exact strings it exists to hide. A
//      denylist of secrets is a list of secrets.
//   2. It only catches what someone remembered to add. The first list missed
//      four domain-revealing filenames that were sitting in the docs while it
//      reported clean.
//
// So: match the SHAPE, not the name. Any project source filename is denied by
// default; project-neutral names are allowed, and a legitimate mention is
// annotated in place. The exception then lives next to the usage, where it
// documents itself and reveals nothing the same line does not already show.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, basename } from "node:path";

const ROOT = process.cwd();

const ID_PATTERNS = [
  // An issue-tracker key of any prefix — this deliberately does not name the
  // private tracker's own prefix.
  [/\b[A-Z]{2,4}-\d{3,}\b/g, "issue-tracker id"],
  [/(?:\bPRs?\s*)?#\d{3,}\b/g, "PR/issue number"],
];
// Technical tokens that share the tracker-id shape.
const NOT_AN_ID = /^(SHA|ISO|UTF|RFC|AES|RGB|CVE)-/;

// Default-deny on source filenames. Everything here is a name any project could
// have; it identifies nothing.
const SOURCE_FILE = /\b[a-z][a-z0-9_]{2,}\.(?:rs|py)\b/g;
const NEUTRAL_FILES = new Set([
  "lib.rs", "main.rs", "mod.rs", "build.rs",
  "foo.rs", "bar.rs", "file.rs", "example.rs",
  "foo.py", "setup.py", "conftest.py", "test_foo.py",
]);
// Build machinery, allowed by SHAPE rather than by name. Tooling is verb-prefixed
// — it checks, runs, generates, builds something — while product modules are
// nouns (`combat_systems`, `lighting`, `attack_system`). The distinction says
// "this file is part of a build, not part of a product", which is true of every
// repo and identifies none. An agent has to be able to name the guard that will
// fail its push, so these cannot simply be banned.
const TOOLING = /^(?:check|run|generate|build|validate|convert|process|export|optimize)_/;

// The downstream repo name is read from the environment, never written down.
// Absent (CI) → this one check is skipped and said so; the structural checks,
// which are the ones that catch new leaks, still run.
const DOWNSTREAM = process.env.PAPERCLIP_PROJECT
  ? basename(process.env.PAPERCLIP_PROJECT.replace(/\/+$/, ""))
  : null;

// A line may opt out with `<!-- privacy-ok: reason -->` when the token is
// genuinely generic or operationally required (a filename the agent must be
// able to name in order to obey the rule).
const OPT_OUT = /<!--\s*privacy-ok:/;

const walk = (d) => readdirSync(d).flatMap((f) => {
  const p = join(d, f);
  return statSync(p).isDirectory() ? walk(p) : p.endsWith(".md") ? [p] : [];
});

let failures = 0, scanned = 0;
for (const file of walk(join(ROOT, "agents"))) {
  scanned++;
  const rel = relative(ROOT, file);
  let fenced = false;
  readFileSync(file, "utf8").split("\n").forEach((line, i) => {
    if (line.trim().startsWith("```")) { fenced = !fenced; return; }
    if (OPT_OUT.test(line)) return;
    const hits = [];
    for (const [re, what] of ID_PATTERNS) {
      for (const m of line.matchAll(re)) {
        if (NOT_AN_ID.test(m[0])) continue;
        hits.push(`${what}: ${m[0]}`);
      }
    }
    for (const m of line.matchAll(SOURCE_FILE)) {
      if (NEUTRAL_FILES.has(m[0]) || TOOLING.test(m[0])) continue;
      hits.push(`project source filename: ${m[0]}`);
    }
    if (DOWNSTREAM && DOWNSTREAM.length > 3 && line.includes(DOWNSTREAM)) {
      hits.push("downstream repo name");
    }
    for (const h of hits) { console.error(`  ${rel}:${i + 1}  ${h}`); failures++; }
  });
}

if (!DOWNSTREAM) {
  console.log("check:agent-privacy — note: PAPERCLIP_PROJECT unset, repo-name check skipped.");
}
if (failures) {
  console.error(`\ncheck:agent-privacy — ${failures} private reference(s) in ${scanned} public file(s).`);
  console.error(`Keep the lesson, drop the pointer: say what happened and what it cost,`);
  console.error(`without the tracker id, PR number, repo name or module name.`);
  console.error(`A genuinely generic or operationally required token: add`);
  console.error(`\`<!-- privacy-ok: why -->\` to that line.`);
  process.exit(1);
}
console.log(`check:agent-privacy — ${scanned} file(s), no private references.`);
