import express, { Router } from "express";
import fs from "node:fs";
import path from "node:path";
import { applyUiBranding } from "./ui-branding.js";

/**
 * Serves a built UI from `uiDist`: the files themselves, and `index.html` for
 * every other path so client-side routes resolve.
 *
 * `index.html` is re-read whenever the file changes. A build replaces it and
 * deletes the hashed chunks the previous one named, and the server is often
 * already running when that happens (a pull restarts it before the build
 * finishes). A copy held from startup keeps naming chunks that no longer exist,
 * and the UI goes blank until the server is restarted by hand.
 *
 * A missing file under `assets/` is a 404, never `index.html`: the browser
 * would load the HTML as a module script and fail with a MIME-type error that
 * hides the real cause.
 */
export function staticUiRouter(uiDist: string): Router {
  const indexPath = path.join(uiDist, "index.html");
  let cached: { mtimeMs: number; size: number; html: string } | null = null;

  const readIndexHtml = (): string => {
    const stat = fs.statSync(indexPath);
    if (!cached || cached.mtimeMs !== stat.mtimeMs || cached.size !== stat.size) {
      cached = {
        mtimeMs: stat.mtimeMs,
        size: stat.size,
        html: applyUiBranding(fs.readFileSync(indexPath, "utf-8")),
      };
    }
    return cached.html;
  };

  const router = Router();
  router.use(express.static(uiDist, { index: false }));
  router.use("/assets", (_req, res) => {
    res.status(404).set("Cache-Control", "no-store").end();
  });
  router.get(/.*/, (_req, res, next) => {
    let html: string;
    try {
      html = readIndexHtml();
    } catch (err) {
      next(err);
      return;
    }
    res.status(200).set({ "Content-Type": "text/html", "Cache-Control": "no-cache" }).end(html);
  });
  return router;
}
