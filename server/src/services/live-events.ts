import { EventEmitter } from "node:events";
import type { LiveEvent, LiveEventType } from "@paperclipai/shared";

type LiveEventPayload = Record<string, unknown>;
type LiveEventListener = (event: LiveEvent) => void;

const LIVE_EVENT_CHANNEL = "live-event";

const emitter = new EventEmitter();
emitter.setMaxListeners(0);

let nextEventId = 0;

export function publishLiveEvent(input: {
  type: LiveEventType;
  payload?: LiveEventPayload;
}): LiveEvent {
  nextEventId += 1;
  const event: LiveEvent = {
    id: nextEventId,
    type: input.type,
    createdAt: new Date().toISOString(),
    payload: input.payload ?? {},
  };
  emitter.emit(LIVE_EVENT_CHANNEL, event);
  return event;
}

export function subscribeLiveEvents(listener: LiveEventListener) {
  emitter.on(LIVE_EVENT_CHANNEL, listener);
  return () => emitter.off(LIVE_EVENT_CHANNEL, listener);
}
