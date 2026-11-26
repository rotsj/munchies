// Bass roots and close keyboard voicings, scored as MIDI notes.
const eMajor9 = { root: 40, keys: [56, 59, 63, 66] };
const eSixNine = { root: 40, keys: [56, 59, 61, 66] };
const cSharpMinor9 = { root: 37, keys: [52, 56, 59, 63] };
const aMajor9 = { root: 45, keys: [56, 59, 61, 64] };
const aMinor6 = { root: 45, keys: [57, 60, 64, 66] };
const bSuspended = { root: 47, keys: [57, 61, 64, 68] };
const bThirteen = { root: 47, keys: [57, 61, 63, 68] };
const bSixNine = { root: 47, keys: [54, 56, 61, 63] };
const gSharpMinor7 = { root: 44, keys: [54, 59, 63, 66] };
const fSharpMinor9 = { root: 42, keys: [57, 61, 64, 68] };

// Each bar pairs a chord with optional melody notes: beat, pitch, and length in beats.
const score = [
  [eMajor9, [[1.45, 71, 0.88], [2.82, 66, 0.55]]],
  [cSharpMinor9, [[0.75, 68, 0.95]]],
  [aMajor9, []],
  [bSuspended, [[2.5, 66, 0.57], [3.42, 69, 0.42]]],
  [{ ...eSixNine, root: 44 }, [[1.1, 71, 0.62], [1.88, 73, 0.65], [2.9, 71, 0.56]]],
  [gSharpMinor7, [[1.3, 68, 1.11]]],
  [fSharpMinor9, []],
  [bThirteen, [[2.66, 66, 0.54], [3.4, 63, 0.48]]],

  [aMajor9, [[1.1, 68, 0.74], [2.58, 71, 0.55]]],
  [bSixNine, [[0.58, 73, 0.96]]],
  [gSharpMinor7, []],
  [cSharpMinor9, [[2.15, 68, 0.58], [2.91, 64, 0.68]]],
  [fSharpMinor9, [[1.5, 69, 0.86]]],
  [aMajor9, []],
  [{ ...eMajor9, root: 44 }, [[1.38, 66, 0.64], [2.8, 68, 0.8]]],
  [bSuspended, []],

  [eMajor9, [[1.75, 71, 0.96]]],
  [eSixNine, []],
  [cSharpMinor9, [[2.05, 68, 0.72], [3.31, 66, 0.5]]],
  [{ ...fSharpMinor9, root: 45 }, []],
  [aMajor9, [[1.55, 69, 0.96]]],
  [aMinor6, [[1.2, 64, 0.68], [2.84, 66, 0.7]]],
  [{ ...eMajor9, root: 47 }, [[1.75, 68, 1.2]]],
  [bThirteen, []],

  [gSharpMinor7, [[1.1, 63, 0.63], [2.35, 66, 0.95]]],
  [cSharpMinor9, [[0.75, 68, 1.04]]],
  [fSharpMinor9, []],
  [bThirteen, [[2.53, 66, 0.55], [3.29, 69, 0.45]]],
  [aMajor9, [[1.52, 71, 0.66]]],
  [bSuspended, [[2.1, 68, 0.74]]],
  [eMajor9, [[0.65, 66, 0.65], [1.5, 64, 1.15]]],
  [eSixNine, []],
];

// Gentle syncopation with alternating downbeat and offbeat chords.
const chordRhythms = [
  [[0, 1.68, 0.136], [2.52, 0.94, 0.104]],
  [[0.42, 1.2, 0.117], [2.18, 1.32, 0.097]],
  [[0, 2.05, 0.128], [3.02, 0.62, 0.086]],
  [[0.4, 1.42, 0.121], [2.53, 0.96, 0.095]],
];

const beatsPerBar = 4;
const beat = 60 / 100;
const sampleRate = 16_000;
const musicGain = 0.105;
const fadeSeconds = 0.045;
const tracks = new WeakMap();

const voices = {
  keys: {
    attack: 0.023, release: 0.13, decay: 1.18,
    tone(phase, time) {
      const strike = Math.exp(-6.5 * time);
      const modulation = (0.09 + 0.21 * strike) * Math.sin(phase * 2.006);
      return Math.sin(phase + modulation) + 0.075 * strike * Math.sin(2 * phase);
    },
  },
  bass: {
    attack: 0.022, release: 0.085, decay: 2.45,
    tone(phase, time) {
      return Math.sin(phase) + Math.exp(-3.7 * time) * (0.28 * Math.sin(2 * phase) + 0.08 * Math.sin(3 * phase));
    },
  },
};

function renderNote(note, length, voice) {
  const sound = new Float32Array(length);
  const phaseStep = (2 * Math.PI * 440 * 2 ** ((note - 69) / 12)) / sampleRate;
  for (let offset = 0; offset < length; offset++) {
    const time = offset / sampleRate;
    const envelope = Math.min(1, time / voice.attack, (length - 1 - offset) / (voice.release * sampleRate));
    sound[offset] = envelope * Math.exp(-voice.decay * time) * voice.tone(phaseStep * offset, time);
  }
  return sound;
}

function renderPercussion() {
  const kick = new Float32Array(Math.round(0.19 * sampleRate));
  let phase = 0;
  for (let i = 0; i < kick.length; i++) {
    const time = i / sampleRate;
    phase += (2 * Math.PI * (52 + 31 * Math.exp(-37 * time))) / sampleRate;
    const envelope = Math.min(1, time / 0.005, (kick.length - i - 1) / (0.02 * sampleRate));
    kick[i] = envelope * Math.exp(-23 * time) * Math.sin(phase);
  }

  const brush = new Float32Array(Math.round(0.16 * sampleRate));
  let seed = 0x3f9616b1;
  let filtered = 0;
  for (let i = 0; i < brush.length; i++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    const noise = (seed / 0x80000000) - 1;
    filtered += 0.17 * (noise - filtered);
    const time = i / sampleRate;
    const envelope = Math.min(1, time / 0.009, (brush.length - i - 1) / (0.02 * sampleRate));
    brush[i] = envelope * Math.exp(-19 * time) * filtered;
  }
  return { kick, brush };
}

function mix(samples, sound, start, strength) {
  const from = Math.round(start * sampleRate);
  for (let i = 0; i < sound.length; i++) {
    samples[(from + i) % samples.length] += strength * sound[i];
  }
}

function renderLoop(context) {
  const buffer = context.createBuffer(1, Math.round(score.length * beatsPerBar * beat * sampleRate), sampleRate);
  const samples = buffer.getChannelData(0);
  const notes = new Map();
  const { kick, brush } = renderPercussion();
  const addNote = (voice, pitch, start, duration, strength) => {
    const length = Math.round(duration * sampleRate);
    const key = `${voice}-${pitch}-${length}`;
    let sound = notes.get(key);
    if (!sound) {
      sound = renderNote(pitch, length, voices[voice]);
      notes.set(key, sound);
    }
    mix(samples, sound, start, strength);
  };

  for (const [bar, [chord, melody]] of score.entries()) {
    const downbeat = bar * beatsPerBar * beat;
    for (const [at, length, strength] of chordRhythms[bar % chordRhythms.length]) {
      for (const [voice, pitch] of chord.keys.entries()) {
        addNote('keys', pitch, downbeat + at * beat + voice * 0.004, length * beat, strength);
      }
    }
    addNote('bass', chord.root, downbeat, 1.10 * beat, 0.29);
    addNote('bass', chord.root + 7, downbeat + 1.54 * beat, 0.56 * beat, 0.19);
    addNote('bass', chord.root + (bar % 2 ? 12 : 0), downbeat + 2.52 * beat, 0.82 * beat, 0.23);
    if (bar % 4 === 3) {
      const [next] = score[(bar + 1) % score.length];
      addNote('bass', next.root + 7, downbeat + 3.58 * beat, 0.43 * beat, 0.14);
    }

    for (const [at, pitch, length] of melody) {
      addNote('keys', pitch, downbeat + at * beat, length * beat, 0.25);
      addNote('keys', pitch, downbeat + at * beat + 0.14, length * beat, 0.035);
    }
    mix(samples, kick, downbeat, 0.18);
    mix(samples, kick, downbeat + (bar % 2 ? 2.56 : 2) * beat, 0.11);
    mix(samples, brush, downbeat + 1.045 * beat, 0.16);
    mix(samples, brush, downbeat + 3.03 * beat, 0.19);
  }
  return buffer;
}

export function setMusicPlaying(context, playing) {
  let track = tracks.get(context);
  const now = context.currentTime;
  if (!playing) {
    if (!track?.playback) return;
    const { source, volume, startedAt } = track.playback;
    track.offset = (track.offset + Math.max(0, now - startedAt)) % track.buffer.duration;
    track.playback = null;
    volume.gain.cancelScheduledValues(now);
    volume.gain.setValueAtTime(volume.gain.value, now);
    volume.gain.linearRampToValueAtTime(0, now + fadeSeconds);
    source.stop(now + fadeSeconds);
    return;
  }

  if (!track) {
    track = { buffer: renderLoop(context), offset: 0, playback: null };
    tracks.set(context, track);
  }
  if (track.playback) return;
  const source = context.createBufferSource();
  const volume = context.createGain();
  source.buffer = track.buffer;
  source.loop = true;
  source.connect(volume);
  volume.connect(context.destination);
  volume.gain.setValueAtTime(0, now);
  volume.gain.linearRampToValueAtTime(musicGain, now + fadeSeconds);
  source.onended = () => {
    source.disconnect();
    volume.disconnect();
  };
  source.start(now, track.offset);
  track.playback = { source, volume, startedAt: now };
}
