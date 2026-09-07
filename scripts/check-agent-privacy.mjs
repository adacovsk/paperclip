#!/usr/bin/env node
// Keeps the private project out of the public repo.
//
// WHY. `agents/**` configures this instance against a PRIVATE downstream repo,
// but paperclip itself is PUBLIC and ships `agents/` in the npm package (no
// `files` field, no `.npmignore`). Every rule in those docs was bought with a
// real incident, and writing the incident down is what stops the rule being
// re-litigated — so the narration stays. What must not stay is anything that
// identifies the private project: its tracker ids, its PR numbers, its repo
// name, its module names.
//
// Keep the lesson, drop the pointer. "One task held a build slot 1h40m while ten
// verifies queued" carries the whole argument; "AA-3253 held it while #684
// waited on `tests/core_mechanics.rs`" adds nothing a public reader can use and
// leaks a private tree.
//
// This is a ratchet, not a cleanup: the scrub is worth doing once, but only a
// guard stops the next edit re-introducing it.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const ROOT = process.cwd();
const SCAN_DIRS = ["agents"];

// Classes of identifier that point into the private tracker or repo.
const PATTERNS = [
  [/\bAA-\d+\b/g, "private tracker id"],
  [/(?:\bPRs?\s*)?#\d{3,}\b/g, "private repo PR/issue number"],
  [/\brust-bevy-rpg\b|\bbevy-rpg\b/g, "private repo name"],
];

// Literal names from the private tree that reveal what it IS — its domain, its
// systems, its content model.
//
// The line here is operational necessity, not caution. Names the instructions
// must contain to work — `docs/ROADMAP.md`, `scripts/check_*.py`,
// `generate_schemas`, `src/`, `tests/*.rs`, `assets/schemas/` — are deliberately
// absent: an agent cannot follow a rule about a file it is forbidden to name,
// and those names describe a build, not a product. What is listed is the set
// that tells a reader what the private project does.
const PRIVATE_TERMS = [
  "core_mechanics.rs", "combat_systems.rs", "active_modifiers.rs",
  "damage_system.rs", "terrain_system.rs", "transitions.rs",
  "spawn_campaign_characters", "check_condition_names.py",
];

// A line may opt out with a trailing `<!-- privacy-ok: reason -->` when the token
// is genuinely generic (an illustrative example, a pattern being defined here).
const OPT_OUT = /<!--\s*privacy-ok:/;

const walk = (d) => readdirSync(d).flatMap((f) => {
  const p = join(d, f);
  return statSync(p).isDirectory() ? walk(p) : p.endsWith(".md") ? [p] : [];
});

let failures = 0, scanned = 0;
for (const dir of SCAN_DIRS) {
  for (const file of walk(join(ROOT, dir))) {
    scanned++;
    const rel = relative(ROOT, file);
    readFileSync(file, "utf8").split("\n").forEach((line, i) => {
      if (OPT_OUT.test(line)) return;
      const hits = [];
      for (const [re, what] of PATTERNS) {
        for (const m of line.matchAll(re)) hits.push(`${what}: ${m[0]}`);
      }
      for (const t of PRIVATE_TERMS) if (line.includes(t)) hits.push(`private name: ${t}`);
      for (const h of hits) {
        console.error(`  ${rel}:${i + 1}  ${h}`);
        failures++;
      }
    });
  }
}

if (failures) {
  console.error(`\ncheck:agent-privacy — ${failures} private reference(s) in ${scanned} public file(s).`);
  console.error(`Keep the lesson, drop the pointer: state what happened and what it cost,`);
  console.error(`without the tracker id, PR number, repo name or module name.`);
  process.exit(1);
}
console.log(`check:agent-privacy — ${scanned} file(s), no private references.`);
