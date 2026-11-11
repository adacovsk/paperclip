import express, { Router, type RequestHandler } from "express";
import fs from "node:fs";
import path from "node:path";
import { applyUiBranding } from "./ui-branding.js";

type FoundIndex = { dir: string; indexPath: string; stat: fs.Stats };

/**
 * Serves a built UI: the files themselves, and `index.html` for every other
 * path so client-side routes resolve. `candidates` are the directories a build
 * may live in, in order of preference.
 *
 * Which directory holds the build is decided per request, never once at
 * startup. A deploy restarts the server while the UI build may still be
 * running, and the build empties its output directory first: a server that
 * looked once and found no `index.html` would stay API-only until restarted by
 * hand.
 *
 * `index.html` is re-read whenever the file changes. A build replaces it and
 * deletes the hashed chunks the previous one named, so a copy held from an
 * earlier read keeps naming chunks that no longer exist and the UI goes blank.
 *
 * A missing file under `assets/` is a 404, never `index.html`: the browser
 * would load the HTML as a module script and fail with a MIME-type error that
 * hides the real cause.
 */
export function staticUiRouter(candidates: readonly string[]): Router {
  const staticByDir = new Map<string, RequestHandler>(
    candidates.map((dir) => [dir, express.static(dir, { index: false })]),
  );
  let cached: { indexPath: string; mtimeMs: number; size: number; html: string } | null = null;

  const findIndex = (): FoundIndex | null => {
    for (const dir of candidates) {
      const indexPath = path.join(dir, "index.html");
      try {
        const stat = fs.statSync(indexPath);
        if (stat.isFile()) return { dir, indexPath, stat };
      } catch {
        // Not built here, or mid-build: try the next candidate.
      }
    }
    return null;
  };

  const readIndexHtml = ({ indexPath, stat }: FoundIndex): string => {
    if (
      !cached ||
      cached.indexPath !== indexPath ||
      cached.mtimeMs !== stat.mtimeMs ||
      cached.size !== stat.size
    ) {
      cached = {
        indexPath,
        mtimeMs: stat.mtimeMs,
        size: stat.size,
        html: applyUiBranding(fs.readFileSync(indexPath, "utf-8")),
      };
    }
    return cached.html;
  };

  const router = Router();
  router.use((req, res, next) => {
    const found = findIndex();
    if (!found) {
      res
        .status(503)
        .set({ "Content-Type": "text/plain", "Cache-Control": "no-store", "Retry-After": "5" })
        .end("The UI build is not available yet. If a build is running, reload when it finishes.");
      return;
    }
    res.locals.uiIndex = found;
    staticByDir.get(found.dir)!(req, res, next);
  });
  router.use("/assets", (_req, res) => {
    res.status(404).set("Cache-Control", "no-store").end();
  });
  router.get(/.*/, (_req, res, next) => {
    let html: string;
    try {
      html = readIndexHtml(res.locals.uiIndex as FoundIndex);
    } catch (err) {
      next(err);
      return;
    }
    res.status(200).set({ "Content-Type": "text/html", "Cache-Control": "no-cache" }).end(html);
  });
  return router;
}
