#if canImport(UIKit)
import Foundation
import QuartzCore
import UIKit
import XCTest

// This fork's parts of the send flight tests, kept out of
// HostedSendFlightTests.swift so merges from upstream do not conflict there.
extension HostedSendFlightTests {
    /// Samples every display frame, and once more as the flight is
    /// committed. The render server starts the flight at its commit, but
    /// the main thread can stay busy for frames after it (a send over the
    /// keyboard does, 30 ms in some runs), and the first frame's callback
    /// then comes two frames into the flight: the sample at the commit is
    /// where the flight starts.
    final class Sampler: NSObject {
        let sample: () -> Sample
        private var link: CADisplayLink?
        private var observer: CFRunLoopObserver?
        private var flying = false
        var samples: [Sample] = []
        init(_ sample: @escaping () -> Sample) { self.sample = sample }
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
            // As the main thread is about to wait, after Core Animation's own
            // commit there, until the flight is seen.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue, true, CFIndex.max) { [weak self] _, _ in
                self?.committed()
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            self.observer = observer
        }
        func stop() {
            link?.invalidate(); link = nil
            observer.map { CFRunLoopObserverInvalidate($0) }; observer = nil
        }
        @objc private func tick() { add(sample()) }
        private func committed() {
            guard !flying else { return }
            let sample = sample()
            // A presentation, once read, is kept until the transaction it
            // was read in commits. This one is read after the run loop's
            // commit, so without this the next frame's callback, if the
            // main thread is held before it, reads the glide as it was here.
            CATransaction.flush()
            if sample.bubble != nil { add(sample) }
        }
        private func add(_ sample: Sample) {
            flying = flying || sample.bubble != nil
            samples.append(sample)
        }
    }
}
#endif
