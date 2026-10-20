import Testing
@testable import AppleVisualizedMusic

@Suite struct PlaybackClockTests {
    @Test func countsForwardWhilePlaying() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 30, playing: true, at: 1000)
        #expect(clock.position(at: 1012.5) == 42.5)
    }

    @Test func standsStillWhilePaused() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 30, playing: false, at: 1000)
        #expect(clock.position(at: 1060) == 30)
    }

    @Test func pausingFreezesWhereItGotTo() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 10, playing: true, at: 0)
        clock.setPlaying(false, at: 5)
        #expect(clock.position(at: 50) == 15)
        clock.setPlaying(true, at: 50)
        #expect(clock.position(at: 52) == 17)
    }

    @Test func neverRunsPastTheEndOrBeforeTheStart() {
        var clock = PlaybackClock()
        clock.duration = 180
        clock.sync(position: 175, playing: true, at: 0)
        #expect(clock.position(at: 60) == 180)
        clock.sync(position: -3, playing: false, at: 0)
        #expect(clock.position(at: 0) == 0)
    }

    @Test func unknownLengthKeepsCounting() {
        var clock = PlaybackClock()   // radio: duration 0
        clock.sync(position: 0, playing: true, at: 0)
        #expect(clock.position(at: 7200) == 7200)
    }

    @Test func holdsStillWhileMusicIsBuffering() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 40, playing: true, at: 0)
        clock.sync(position: 40.1, playing: true, at: 2)    // "playing", but barely moved
        #expect(clock.isStalled)
        #expect(clock.position(at: 6) == 40.1)                // doesn't run ahead
        clock.sync(position: 40.6, playing: true, at: 2.5)  // moving again
        #expect(!clock.isStalled)
        #expect(clock.position(at: 4.5) == 42.6)
    }

    @Test func aSteadyPlayheadIsNotAStall() {
        var clock = PlaybackClock()
        clock.duration = 200
        for step in 0..<10 {
            clock.sync(position: 10 + Double(step) * 2, playing: true, at: Double(step) * 2)
            #expect(!clock.isStalled)
        }
    }

    @Test func aSeekIsNotAStall() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 100, playing: true, at: 0)
        clock.sync(position: 20, playing: true, at: 2)      // seeked back in Music
        #expect(!clock.isStalled)
    }

    @Test func timeSpentPausedIsNotAStall() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 50, playing: true, at: 0)
        clock.sync(position: 52, playing: false, at: 2)
        clock.sync(position: 52, playing: true, at: 60)     // resumed after a minute
        #expect(!clock.isStalled)
        clock.setPlaying(true, at: 61)
        clock.sync(position: 53.5, playing: true, at: 62.5)
        #expect(!clock.isStalled)
    }

    @Test func readingsTooCloseTogetherDontJudge() {
        var clock = PlaybackClock()
        clock.duration = 200
        clock.sync(position: 10, playing: true, at: 0)
        clock.sync(position: 10, playing: true, at: 0.1)
        #expect(!clock.isStalled)
    }

    @Test func formatsLikeMusic() {
        #expect(PlaybackClock.format(0) == "0:00")
        #expect(PlaybackClock.format(7.9) == "0:07")
        #expect(PlaybackClock.format(187) == "3:07")
        #expect(PlaybackClock.format(3723) == "1:02:03")
        #expect(PlaybackClock.format(-5) == "0:00")
    }

    @Test func repeatCyclesInMusicsOrder() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
        #expect(RepeatMode(rawValue: "one") == .one)
    }
}
