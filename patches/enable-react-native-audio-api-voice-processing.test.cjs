const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { patchAudioApiVoiceProcessing, patchSource, iosReplacements } = require('./enable-react-native-audio-api-voice-processing.cjs');

const files = [
    'react-native-audio-api/ios/audioapi/ios/system/AudioEngine.mm',
    'react-native-audio-api/android/src/main/cpp/audioapi/android/core/AndroidAudioRecorder.cpp',
];

function copyInstalled() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'audio-api-vp-'));
    for (const file of files) {
        fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
        fs.copyFileSync(path.join(__dirname, '..', 'node_modules', file), path.join(root, file));
    }
    return root;
}

test('patches the installed sources once, idempotently', () => {
    const root = copyInstalled();
    const before = files.map((f) => fs.readFileSync(path.join(root, f), 'utf8'));
    const firstRun = patchAudioApiVoiceProcessing([root]);
    // Already-patched installs (postinstall ran) count 0; pristine ones count 2.
    assert.ok(firstRun === 0 || firstRun === 2);
    const [ios, android] = files.map((f) => fs.readFileSync(path.join(root, f), 'utf8'));
    assert.match(ios, /\[self enableVoiceProcessingIfRequested\];\n {2}\[self\.audioEngine attachNode:inputNode\];/);
    assert.match(ios, /setVoiceProcessingEnabled:YES/);
    assert.match(android, /setSharingMode\(SharingMode::Shared\)/);
    assert.match(android, /setInputPreset\(InputPreset::VoiceCommunication\)/);
    assert.equal(patchAudioApiVoiceProcessing([root]), 0);
    if (firstRun === 2) assert.notEqual(before[0], ios);
});

test('refuses drifted sources instead of skipping', () => {
    assert.throws(() => patchSource('- (void)somethingElse\n{\n', iosReplacements, 'AudioEngine.mm'), /Unexpected/);
});
