import { VoiceConfigResponseSchema } from "@slopus/happy-wire";
import { afterEach, describe, expect, it, vi } from "vitest";
import { voiceBackendsCurrent, voiceBackendsResolve } from "./voiceBackendsResolve";

function resolve(voiceBackends: string | undefined, isLiveKitConfigured = true, isElevenLabsConfigured = true) {
    return voiceBackendsResolve({ voiceBackends, isLiveKitConfigured, isElevenLabsConfigured });
}

describe("voiceBackendsResolve", () => {
    it.each([undefined, "", "   ", ",", " , "])("detects what is configured when VOICE_BACKENDS is %j", (voiceBackends) => {
        expect(resolve(voiceBackends)).toEqual({
            backends: ["stream", "elevenlabs"],
            defaultBackend: "stream",
            warnings: [],
        });
        expect(resolve(voiceBackends, true, false)).toEqual({ backends: ["stream"], defaultBackend: "stream", warnings: [] });
        expect(resolve(voiceBackends, false, true)).toEqual({ backends: ["elevenlabs"], defaultBackend: "elevenlabs", warnings: [] });
        expect(resolve(voiceBackends, false, false)).toEqual({ backends: [], defaultBackend: null, warnings: [] });
    });

    it("takes the list's order, the first being the default", () => {
        expect(resolve("elevenlabs,stream")).toEqual({
            backends: ["elevenlabs", "stream"],
            defaultBackend: "elevenlabs",
            warnings: [],
        });
    });

    it("offers only what is listed", () => {
        expect(resolve("stream")).toEqual({ backends: ["stream"], defaultBackend: "stream", warnings: [] });
        expect(resolve("elevenlabs")).toEqual({ backends: ["elevenlabs"], defaultBackend: "elevenlabs", warnings: [] });
    });

    it("ignores spaces, empty entries and repeats", () => {
        expect(resolve(" stream , ,elevenlabs,stream,")).toEqual({
            backends: ["stream", "elevenlabs"],
            defaultBackend: "stream",
            warnings: [],
        });
    });

    it("drops a listed backend that is not configured, with a warning", () => {
        expect(resolve("stream,elevenlabs", true, false)).toEqual({
            backends: ["stream"],
            defaultBackend: "stream",
            warnings: ['VOICE_BACKENDS lists "elevenlabs" but it is not configured; dropped'],
        });
        expect(resolve("stream,elevenlabs", false, true)).toEqual({
            backends: ["elevenlabs"],
            defaultBackend: "elevenlabs",
            warnings: ['VOICE_BACKENDS lists "stream" but it is not configured; dropped'],
        });
    });

    it("drops an unknown name, with a warning", () => {
        expect(resolve("livekit,stream")).toEqual({
            backends: ["stream"],
            defaultBackend: "stream",
            warnings: ['VOICE_BACKENDS lists unknown backend "livekit"; dropped'],
        });
    });

    it("warns once for a repeated name", () => {
        expect(resolve("livekit,livekit,stream").warnings).toHaveLength(1);
    });

    it("offers nothing when everything listed is dropped, rather than falling back to detection", () => {
        expect(resolve("livekit")).toMatchObject({ backends: [], defaultBackend: null });
        expect(resolve("elevenlabs", true, false)).toMatchObject({ backends: [], defaultBackend: null });
    });

    it("gives a list and default the wire accepts", () => {
        const { backends, defaultBackend } = resolve("livekit");
        expect(VoiceConfigResponseSchema.parse({ backends, defaultBackend })).toEqual({ backends: [], defaultBackend: null });
    });
});

describe("voiceBackendsCurrent", () => {
    afterEach(() => {
        vi.unstubAllEnvs();
    });

    function stubEnv(env: { liveKit?: boolean; elevenLabs?: string; list?: string }) {
        vi.stubEnv("LIVEKIT_API_KEY", env.liveKit ? "key" : undefined);
        vi.stubEnv("LIVEKIT_API_SECRET", env.liveKit ? "secret" : undefined);
        vi.stubEnv("ELEVENLABS_API_KEY", env.elevenLabs);
        vi.stubEnv("VOICE_BACKENDS", env.list);
    }

    it("reads both backends from the environment", () => {
        stubEnv({ liveKit: true, elevenLabs: "key" });
        expect(voiceBackendsCurrent()).toMatchObject({ backends: ["stream", "elevenlabs"], defaultBackend: "stream" });
    });

    it("treats the empty values compose passes as unset", () => {
        stubEnv({ liveKit: true, elevenLabs: "", list: "" });
        expect(voiceBackendsCurrent()).toEqual({ backends: ["stream"], defaultBackend: "stream", warnings: [] });
    });

    it("needs both the LiveKit key and secret", () => {
        stubEnv({ liveKit: true });
        vi.stubEnv("LIVEKIT_API_SECRET", undefined);
        expect(voiceBackendsCurrent()).toEqual({ backends: [], defaultBackend: null, warnings: [] });
    });

    it("applies VOICE_BACKENDS", () => {
        stubEnv({ liveKit: true, elevenLabs: "key", list: "elevenlabs" });
        expect(voiceBackendsCurrent()).toMatchObject({ backends: ["elevenlabs"], defaultBackend: "elevenlabs" });
    });
});
