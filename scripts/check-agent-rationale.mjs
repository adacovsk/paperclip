#!/usr/bin/env node
// Guards the INSTRUCTIONS / rationale split for agent docs.
//
// WHY THE SPLIT EXISTS. Agent INSTRUCTIONS are re-read on every run, and ~47% of
// their bulk was incident narration — the measured failure behind each rule, with
// dates, task ids and timings. That narration is what stops a rule being
// re-litigated or "tidied" away, so deleting it is not an option; but paying for
// it on every turn of every run is. The rule stays inline where it is obeyed; the
// story moves one hop away, to be read when someone wants to CHANGE the rule
// rather than follow it.
//
// WHY ONE FILE PER RULE, not one per role. The read is always "why does THIS rule
// exist" — never "tell me every reason". A per-role file would be ~8-10k tokens,
// so following one link would re-import most of what the split just removed. It
// is also the shape docs/ROADMAP.md already settled on in the project repo
// (docs/roadmap/<section>.md, one file per section, cycle-guarded) for the same
// reason. A 1:1 link<->file mapping additionally makes "orphaned" exact rather
// than a judgement about headings, and lets a deleted rule take its story with it
// in one `git rm` instead of an edit that leaves a dangling section behind.
//
// Four invariants:
//   1. Every `(rationale/<slug>.md)` link in INSTRUCTIONS resolves to a real file.
//   2. Every file under rationale/ is linked from INSTRUCTIONS. An orphan is
//      narration that lost its rule — exactly how a rule gets deleted and its
//      ghost kept.
//   3. The rule each rationale file claims to justify still EXISTS in
//      INSTRUCTIONS. A rule that moved out of INSTRUCTIONS is a rule the agent
//      stops following, and that failure is silent.
//
//      This is checked through the `**Justifies:**` quote rather than by scanning
//      the narration for normative sentences. Scanning was tried first and is
//      wrong: condensing a rule inline is the entire point of the split, so any
//      near-verbatim test fires on every successful condensation and gets muted.
//      The quote is an exact anchor the author controls, and it fails on the case
//      that matters — delete or reword the rule and its story is orphaned loudly.
//   4. Every rationale file carries a `**Justifies:**` line quoting the rule it
//      defends, so a reader landing there cold knows what it is for — and so a
//      rule that gets reworded leaves a visible mismatch instead of a file whose
//      subject nobody can reconstruct. That line quotes a rule by construction,
//      so it is exempt from invariant 3.
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const AGENTS = join(process.cwd(), "agents");

// Applied to BOTH sides before comparison: a probe built from stripped rationale
// text must be matched against equally stripped INSTRUCTIONS text, or every
// sentence containing code or a quotation reports as missing.
// No stripping. `norm` already discards backticks and every other punctuation
// mark, so an anchor quote matches its inline original regardless of markup.
//
// Two stripping schemes were tried first and both silently deleted real prose,
// making every lookup miss: an inline-code regex run before fence removal pairs
// across whole ``` blocks, and a double-quote regex pairs across the entire
// document. Comparing normalised text avoids the whole class.
const norm = (x) => x.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

let failures = 0, pairs = 0, files = 0;
const fail = (m) => { console.error(`  ${m}`); failures++; };

for (const role of readdirSync(AGENTS)) {
  const dir = join(AGENTS, role);
  if (!statSync(dir).isDirectory()) continue;
  const instPath = join(dir, "INSTRUCTIONS.md");
  const ratDir = join(dir, "rationale");
  if (!existsSync(instPath)) continue;

  const inst = readFileSync(instPath, "utf8");
  const linked = new Set(
    [...inst.matchAll(/\(rationale\/([a-z0-9-]+)\.md\)/g)].map((m) => m[1]),
  );
  const present = existsSync(ratDir)
    ? new Set(readdirSync(ratDir).filter((f) => f.endsWith(".md")).map((f) => f.slice(0, -3)))
    : new Set();

  if (!linked.size && !present.size) continue;
  pairs++; files += present.size;

  for (const l of linked) {
    if (!present.has(l)) fail(`${role}: INSTRUCTIONS links rationale/${l}.md, which does not exist`);
  }
  for (const p of present) {
    if (!linked.has(p)) fail(`${role}: rationale/${p}.md is orphaned — no INSTRUCTIONS rule links it`);
  }

  const instNorm = norm(inst);
  for (const slug of present) {
    const body = readFileSync(join(ratDir, `${slug}.md`), "utf8");
    if (!/^#\s+\S/m.test(body)) fail(`${role}/rationale/${slug}.md: no top-level heading`);
    if (!/^\*\*Justifies:\*\*/m.test(body)) fail(`${role}/rationale/${slug}.md: no "**Justifies:**" line naming the rule it defends`);
    const m = body.match(/^\*\*Justifies:\*\*\s*(.+)$/m);
    if (!m) { fail(`${role}/rationale/${slug}.md: no "**Justifies:**" line naming the rule it defends`); continue; }
    // The quoted span is the anchor: the rule as it is worded in INSTRUCTIONS.
    const quoted = [...m[1].matchAll(/\*([^*]{20,})\*/g)].map((q) => q[1]);
    if (!quoted.length) { fail(`${role}/rationale/${slug}.md: Justifies line must quote the rule in *italics*`); continue; }
    for (const q of quoted) {
      if (!instNorm.includes(norm(q))) {
        fail(`${role}/rationale/${slug}.md: the rule it justifies is no longer in INSTRUCTIONS:\n      "${q.slice(0, 100)}"\n      Either the rule was deleted (delete this file too) or reworded (update the Justifies quote).`);
      }
    }
  }
}

if (failures) { console.error(`\ncheck:agent-rationale — ${failures} problem(s).`); process.exit(1); }
console.log(`check:agent-rationale — ${pairs} agent(s), ${files} rationale file(s), clean.`);
