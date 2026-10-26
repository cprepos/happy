/**
 * react-native-audio-api 0.8.x records without echo cancellation: the iOS
 * AVAudioEngine never enables voice processing, and the Android Oboe input
 * stream is opened Exclusive with no input preset. The voice assistant plays
 * the agent through the speaker while the mic is open, so without AEC the
 * agent hears itself.
 *
 * - iOS: enable voice processing on the engine's input node (before it is
 *   connected) when the session mode is voiceChat/videoChat. Only the voice
 *   session sets that mode (nativeVoiceAudio.ts), so other recorder users
 *   are unaffected. Also re-enabled when the engine is rebuilt.
 * - Android: open the input stream Shared with the VoiceCommunication preset,
 *   which turns on the platform AEC/NS/AGC effects.
 *
 * Native code: takes effect only in a new native build, never via OTA.
 */
const fs = require('node:fs');
const path = require('node:path');

const IOS_FILE = 'react-native-audio-api/ios/audioapi/ios/system/AudioEngine.mm';
const ANDROID_FILE = 'react-native-audio-api/android/src/main/cpp/audioapi/android/core/AndroidAudioRecorder.cpp';

const IOS_HELPER = `- (void)enableVoiceProcessingIfRequested
{
  // Patched by happy (enable-react-native-audio-api-voice-processing.cjs).
  NSString *mode = [AVAudioSession sharedInstance].mode;
  if (![mode isEqualToString:AVAudioSessionModeVoiceChat] && ![mode isEqualToString:AVAudioSessionModeVideoChat]) {
    return;
  }
  AVAudioInputNode *input = self.audioEngine.inputNode;
  if (input.isVoiceProcessingEnabled) {
    return;
  }
  NSError *error = nil;
  if (![input setVoiceProcessingEnabled:YES error:&error]) {
    NSLog(@"[AudioEngine] enabling voice processing failed: %@", error);
  }
}

`;

const iosReplacements = [
    ['- (void)rebuildAudioEngine\n{\n',
        IOS_HELPER + '- (void)rebuildAudioEngine\n{\n'
        + '  if (self.inputNode) {\n    [self enableVoiceProcessingIfRequested];\n  }\n\n'],
    ['  self.inputNode = inputNode;\n\n  [self.audioEngine attachNode:inputNode];',
        '  self.inputNode = inputNode;\n\n  [self enableVoiceProcessingIfRequested];\n  [self.audioEngine attachNode:inputNode];'],
];

const androidReplacements = [
    ['builder.setSharingMode(SharingMode::Exclusive)\n      ->setDirection(Direction::Input)',
        'builder.setSharingMode(SharingMode::Shared)\n      ->setDirection(Direction::Input)\n'
        + '      ->setInputPreset(InputPreset::VoiceCommunication)'],
];

/** Applies all replacements, or none if already applied; throws on drifted sources. */
function patchSource(source, replacements, name) {
    if (replacements.every(([, after]) => source.includes(after))) return source;
    for (const [before] of replacements) {
        if (source.split(before).length !== 2) {
            throw new Error(`[patch] Unexpected ${name} source; review enable-react-native-audio-api-voice-processing.cjs`);
        }
    }
    for (const [before, after] of replacements) source = source.replace(before, after);
    return source;
}

function patchAudioApiVoiceProcessing(nodeModulesRoots = [
    path.resolve(__dirname, '..', 'node_modules'),
    path.resolve(__dirname, '..', 'packages/happy-app/node_modules'),
]) {
    let patched = 0;
    for (const root of nodeModulesRoots) {
        for (const [file, replacements] of [[IOS_FILE, iosReplacements], [ANDROID_FILE, androidReplacements]]) {
            const target = path.join(root, file);
            if (!fs.existsSync(target)) continue;
            const source = fs.readFileSync(target, 'utf8');
            const next = patchSource(source, replacements, path.basename(file));
            if (next !== source) {
                // Replace the file rather than writing through it: node_modules
                // may hardlink into the shared package store.
                fs.writeFileSync(`${target}.tmp`, next, 'utf8');
                fs.renameSync(`${target}.tmp`, target);
                patched++;
            }
        }
    }
    if (patched > 0) {
        console.log(`[patch] Enabled react-native-audio-api voice processing (${patched} file(s))`);
    }
    return patched;
}

module.exports = { iosReplacements, androidReplacements, patchSource, patchAudioApiVoiceProcessing };
if (require.main === module) patchAudioApiVoiceProcessing();
