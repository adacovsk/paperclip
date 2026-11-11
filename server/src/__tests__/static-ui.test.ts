import express from "express";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import request from "supertest";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { staticUiRouter } from "../static-ui.ts";

describe("staticUiRouter", () => {
  let dist: string;

  const writeBuild = (hash: string) => {
    fs.rmSync(path.join(dist, "assets"), { recursive: true, force: true });
    fs.mkdirSync(path.join(dist, "assets"), { recursive: true });
    fs.writeFileSync(path.join(dist, "assets", `index-${hash}.js`), `console.log("${hash}");`);
    fs.writeFileSync(
      path.join(dist, "index.html"),
      `<!doctype html><html><head><script type="module" src="/assets/index-${hash}.js"></script></head></html>`,
    );
  };

  const app = () => express().use(staticUiRouter(dist));

  beforeEach(() => {
    dist = fs.mkdtempSync(path.join(os.tmpdir(), "static-ui-"));
    writeBuild("aaaa1111");
  });

  afterEach(() => {
    fs.rmSync(dist, { recursive: true, force: true });
  });

  it("serves index.html for client routes and the root", async () => {
    const server = app();
    for (const url of ["/", "/issues", "/AA/issues/AA-1"]) {
      const res = await request(server).get(url);
      expect(res.status).toBe(200);
      expect(res.headers["content-type"]).toContain("text/html");
      expect(res.text).toContain("/assets/index-aaaa1111.js");
    }
  });

  it("serves the index.html of a build made after the server started", async () => {
    const server = app();
    await request(server).get("/issues");

    writeBuild("bbbb2222");
    // Guarantee a different mtime even on coarse-timestamp filesystems.
    const later = new Date(Date.now() + 5_000);
    fs.utimesSync(path.join(dist, "index.html"), later, later);

    const res = await request(server).get("/issues");
    expect(res.text).toContain("/assets/index-bbbb2222.js");
    expect(res.text).not.toContain("aaaa1111");
  });

  it("serves existing assets and 404s missing ones instead of returning HTML", async () => {
    const server = app();
    const hit = await request(server).get("/assets/index-aaaa1111.js");
    expect(hit.status).toBe(200);
    expect(hit.headers["content-type"]).toContain("javascript");

    const miss = await request(server).get("/assets/index-gone0000.js");
    expect(miss.status).toBe(404);
    expect(miss.headers["content-type"] ?? "").not.toContain("text/html");
  });
});
