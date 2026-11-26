import JavaScriptKit
import WASILibc

/// Procedural WebAudio API synthesizer with +1 semitone/cascade pitch escalation
/// and iOS Safari standalone PWA first-gesture AudioContext unlock.
final class WebAudioManager {
    var soundEffectsEnabled: Bool = true
    var goofySnoreSoundsEnabled: Bool = true

    private var audioCtx: JSObject?

    /// Must be called on the first `pointerdown` gesture so iOS Safari unlocks WebAudio.
    func unlockIfNeeded() {
        if audioCtx == nil {
            let ctor = JSObject.global.AudioContext.function ?? JSObject.global.webkitAudioContext.function
            audioCtx = ctor?.new()
        }
        if let ctx = audioCtx, ctx.state.string == "suspended" {
            _ = ctx.resume?()
        }
    }

    func playMatchPop(cascadeDepth: Int) {
        guard soundEffectsEnabled else { return }
        let semitones = Double(max(0, min(cascadeDepth - 1, 14)))
        let freq = 523.25 * pow(2.0, semitones / 12.0)
        playTone(startFreq: freq, endFreq: freq * 1.12, duration: 0.14, gain: 0.22, type: "triangle")
    }

    func playSwap() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 310, endFreq: 420, duration: 0.06, gain: 0.12, type: "sine")
    }

    func playInvalidSwap() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 210, endFreq: 160, duration: 0.10, gain: 0.14, type: "sine")
    }

    func playSpecialBlast() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 680, endFreq: 180, duration: 0.24, gain: 0.26, type: "sawtooth")
    }

    func playSnoreSpawn() {
        guard goofySnoreSoundsEnabled else { return }
        playTone(startFreq: 110, endFreq: 145, duration: 0.26, gain: 0.18, type: "sawtooth")
    }

    func playSnorePop() {
        guard goofySnoreSoundsEnabled else { return }
        playTone(startFreq: 720, endFreq: 1180, duration: 0.12, gain: 0.16, type: "sine")
    }

    func playPuppyYip() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 640, endFreq: 1280, duration: 0.13, gain: 0.20, type: "triangle")
        playTone(startFreq: 880, endFreq: 1320, duration: 0.22, gain: 0.18, type: "sine", delay: 0.10)
    }

    func playPuppyRescue() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 390, endFreq: 235, duration: 0.13, gain: 0.19, type: "triangle")
        playTone(startFreq: 659.25, endFreq: 659.25, duration: 0.17, gain: 0.18, type: "sine", delay: 0.09)
        playTone(startFreq: 987.77, endFreq: 987.77, duration: 0.25, gain: 0.15, type: "sine", delay: 0.19)
    }

    func playTeidoAchievement() {
        guard soundEffectsEnabled else { return }
        playTone(startFreq: 783.99, endFreq: 783.99, duration: 0.11, gain: 0.18, type: "triangle")
        playTone(startFreq: 1046.50, endFreq: 1046.50, duration: 0.22, gain: 0.22, type: "triangle", delay: 0.10)
    }

    func playTierUp() {
        guard soundEffectsEnabled else { return }
        let notes = [523.25, 659.25, 783.99, 1046.50]
        for (i, freq) in notes.enumerated() {
            playTone(startFreq: freq, endFreq: freq, duration: 0.12, gain: 0.16, type: "triangle", delay: Double(i) * 0.08)
        }
    }

    private func playTone(
        startFreq: Double,
        endFreq: Double,
        duration: Double,
        gain peakGain: Double,
        type: String,
        delay: Double = 0.0
    ) {
        guard let ctx = audioCtx, let now = ctx.currentTime.number else { return }
        let start = now + delay
        let end = start + duration

        guard let osc = ctx.createOscillator?().object,
              let gainNode = ctx.createGain?().object else { return }

        osc.type = .string(type)
        if let freqParam = osc.frequency.object {
            _ = freqParam.setValueAtTime?(startFreq, start)
            if abs(endFreq - startFreq) > 0.5 {
                _ = freqParam.exponentialRampToValueAtTime?(max(20.0, endFreq), end)
            }
        }

        if let gainParam = gainNode.gain.object {
            _ = gainParam.setValueAtTime?(0.0001, start)
            _ = gainParam.linearRampToValueAtTime?(peakGain, start + 0.015)
            _ = gainParam.exponentialRampToValueAtTime?(0.0001, end)
        }

        _ = osc.connect?(gainNode)
        _ = gainNode.connect?(ctx.destination)
        _ = osc.start?(start)
        _ = osc.stop?(end + 0.02)
    }
}
