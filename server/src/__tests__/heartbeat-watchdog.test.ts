import { describe, expect, it } from "vitest";
import { createRunWatchdog } from "../services/heartbeat.ts";

describe("createRunWatchdog", () => {
  it("rejects when abort() is called externally — the reaper-after-process-loss path", async () => {
    const watchdog = createRunWatchdog({ timeoutMs: 60_000 });
    try {
      const onAdapterHang = new Promise(() => {}); // never settles
      const racePromise = Promise.race([onAdapterHang, watchdog.promise]);
      watchdog.abort("process_lost: child pid 999 is no longer running");
      await expect(racePromise).rejects.toMatchObject({
        message: expect.stringContaining("process_lost"),
        code: "watchdog_aborted",
      });
    } finally {
      watchdog.cleanup();
    }
  });

  it("rejects when the hard timeout elapses — the no-reaper-tick fallback", async () => {
    const watchdog = createRunWatchdog({ timeoutMs: 50 });
    try {
      const onAdapterHang = new Promise(() => {});
      const racePromise = Promise.race([onAdapterHang, watchdog.promise]);
      await expect(racePromise).rejects.toMatchObject({
        message: expect.stringContaining("hard timeout"),
        code: "watchdog_aborted",
      });
    } finally {
      watchdog.cleanup();
    }
  });

  it("calls onAbort callback exactly once with the abort reason", async () => {
    const reasons: string[] = [];
    const watchdog = createRunWatchdog({
      timeoutMs: 60_000,
      onAbort: (reason) => reasons.push(reason),
    });
    try {
      watchdog.promise.catch(() => undefined);
      watchdog.abort("first");
      watchdog.abort("second");
      expect(reasons).toEqual(["first"]);
    } finally {
      watchdog.cleanup();
    }
  });

  it("does not fire when the adapter resolves first — the happy path", async () => {
    const watchdog = createRunWatchdog({ timeoutMs: 60_000 });
    try {
      const adapterResult = Promise.resolve({ ok: true });
      const racePromise = Promise.race([adapterResult, watchdog.promise]);
      const result = await racePromise;
      expect(result).toEqual({ ok: true });
    } finally {
      watchdog.cleanup();
    }
  });

  it("restart() defers a timeout that would otherwise have fired — the slot-admission path", async () => {
    // AA-2917: the timer is armed at dispatch, but the build only starts when
    // cargo-sem.sh wins a slot. Without restart(), the queue wait is billed
    // against the build and a saturated semaphore kills every waiter.
    const reasons: string[] = [];
    const watchdog = createRunWatchdog({ timeoutMs: 60, onAbort: (r) => reasons.push(r) });
    try {
      watchdog.promise.catch(() => undefined);
      await new Promise((r) => setTimeout(r, 40));
      expect(watchdog.restart()).toBe(true);
      // Past the ORIGINAL deadline; only the restart keeps it alive here.
      await new Promise((r) => setTimeout(r, 40));
      expect(reasons).toEqual([]);
    } finally {
      watchdog.cleanup();
    }
  });

  it("restart() returns false once the watchdog has already fired", async () => {
    // The wrapper announces admission blind, so it can race a run that just
    // died. That must report false, not resurrect a settled race.
    const watchdog = createRunWatchdog({ timeoutMs: 60_000 });
    watchdog.promise.catch(() => undefined);
    watchdog.abort("process_lost");
    expect(watchdog.restart()).toBe(false);
    watchdog.cleanup();
  });

  it("restart() fires onRestart only while the watchdog is live", async () => {
    const restarts: number[] = [];
    const watchdog = createRunWatchdog({
      timeoutMs: 60_000,
      onRestart: () => restarts.push(1),
    });
    watchdog.promise.catch(() => undefined);
    watchdog.restart();
    watchdog.restart();
    watchdog.abort("done");
    watchdog.restart();
    expect(restarts).toEqual([1, 1]);
    watchdog.cleanup();
  });

  it("cleanup() prevents the timer from firing after the race already settled", async () => {
    const reasons: string[] = [];
    const watchdog = createRunWatchdog({
      timeoutMs: 30,
      onAbort: (reason) => reasons.push(reason),
    });
    const adapterResult = Promise.resolve("done");
    await Promise.race([adapterResult, watchdog.promise]);
    watchdog.cleanup();
    await new Promise((r) => setTimeout(r, 80));
    expect(reasons).toEqual([]);
  });
});
