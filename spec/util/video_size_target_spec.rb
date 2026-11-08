# frozen_string_literal: true

require "spec_helper"

# The arithmetic behind a transcode, on its own and with no binary anywhere near
# it. This is the part most likely to be quietly wrong, so it is the part with
# the most examples.
RSpec.describe Rubotty::Util::VideoSizeTarget do
  MB = 1024 * 1024

  def plan(target: 10 * MB, duration: 60, **rest)
    described_class.for(target_bytes: target, duration: duration, **rest)
  end

  describe "the bitrate it arrives at" do
    # ffmpeg has no flag for a target size, so the size becomes a bitrate: the
    # bits a file may hold, divided by how long it runs, less the audio's share.
    it "divides the budget by the duration and takes the audio off the top" do
      result = plan(target: 10 * MB, duration: 60, height: 1080, width: 1920)
      budget = (10 * MB * 8 * described_class::SAFETY).floor

      expect(result.video_bitrate).to eq((budget / 60.0).floor - described_class::DEFAULT_AUDIO_BITRATE)
      expect(result.audio_bitrate).to eq(described_class::DEFAULT_AUDIO_BITRATE)
    end

    # The margin is what container overhead and a rate controller's overshoot
    # come out of, so the encode aims below the ceiling and not at it.
    it "keeps a margin under the ceiling rather than spending all of it" do
      expect(described_class::SAFETY).to be_between(0.92, 0.95)
      expect(described_class.usable_bits(10 * MB)).to be < 10 * MB * 8
    end

    it "gives a silent video the audio's share to spend on the picture" do
      loud = plan(target: 10 * MB, duration: 60, height: 720, width: 1280)
      quiet = plan(target: 10 * MB, duration: 60, height: 720, width: 1280, audio: false)

      expect(quiet.audio_bitrate).to be_zero
      expect(quiet.video_bitrate - loud.video_bitrate).to eq(described_class::DEFAULT_AUDIO_BITRATE)
    end

    # Twice as long is half the bitrate, which is the whole reason a long video
    # eventually cannot be helped.
    it "halves the bitrate when the video is twice as long" do
      short = plan(target: 20 * MB, duration: 60, height: 720, width: 1280)
      long = plan(target: 20 * MB, duration: 120, height: 720, width: 1280)

      expect(long.video_bitrate).to be_within(1000).of(
        ((short.video_bitrate + described_class::DEFAULT_AUDIO_BITRATE) / 2) -
          described_class::DEFAULT_AUDIO_BITRATE
      )
    end

    it "reports what the two streams add up to, which is what the file aims at" do
      result = plan(target: 10 * MB, duration: 60, height: 720, width: 1280)

      expect(result.total_bitrate).to eq(result.video_bitrate + result.audio_bitrate)
      expect(result.total_bitrate * 60 / 8).to be <= 10 * MB
    end
  end

  describe "the resolution it picks" do
    # The duration fixes the bitrate, so the only thing left to decide is how
    # far that bitrate has to stretch.
    it "leaves a short video at its own height, since the bitrate is plentiful" do
      expect(plan(target: 50 * MB, duration: 30, height: 1080, width: 1920).height).to eq(1080)
    end

    it "steps down when the bitrate would smear the frame it was given" do
      result = plan(target: 10 * MB, duration: 60, height: 1080, width: 1920)

      expect(result.height).to eq(720)
      expect(result.video_bitrate).to be >= described_class.floor_for(720)
      expect(result.video_bitrate).to be < described_class.floor_for(1080)
    end

    it "goes all the way down the ladder for a video long enough to need it" do
      expect(plan(target: 10 * MB, duration: 300, height: 1080, width: 1920).height)
        .to eq(described_class::HEIGHTS.last)
    end

    # Upscaling spends bits inventing detail nobody filmed.
    it "never picks a frame taller than the source" do
      expect(plan(target: 50 * MB, duration: 10, height: 480, width: 854).height).to eq(480)
      expect(plan(target: 50 * MB, duration: 10, height: 240, width: 426).height).to eq(240)
    end

    it "tries the source's own height first when it sits between two rungs" do
      expect(plan(target: 50 * MB, duration: 10, height: 900, width: 1600).height).to eq(900)
    end

    it "caps an enormous source at the tallest rung rather than encoding at 4K" do
      expect(plan(target: 200 * MB, duration: 10, height: 2160, width: 3840).height)
        .to eq(described_class::HEIGHTS.first)
    end

    it "assumes 1080 when the source did not say how tall it is" do
      expect(plan(target: 100 * MB, duration: 10).height).to eq(1080)
    end

    # A tall narrow phone video has far fewer pixels than its height suggests,
    # so the floor is read off the real frame rather than off a 16:9 guess.
    it "measures the floor against the real frame, not an assumed one" do
      expect(described_class.floor_for(1080, 9.0 / 16)).to be < described_class.floor_for(1080)
    end
  end

  describe "when it refuses" do
    # The honest answer, and the reason the link strategy still exists.
    it "gives up on a video too long to reach the ceiling at any watchable rate" do
      expect(plan(target: 2 * MB, duration: 7200, height: 1080, width: 1920)).to be_nil
    end

    it "gives up when there is not even a floor's worth of bitrate to hand out" do
      expect(plan(target: 1 * MB, duration: 3600, height: 360, width: 640)).to be_nil
    end

    # Everything divides by the duration, so a video that never said how long it
    # is cannot be planned for at all.
    it "gives up without a duration" do
      expect(plan(duration: 0)).to be_nil
      expect(plan(duration: nil)).to be_nil
    end

    it "gives up without a target worth aiming at" do
      expect(plan(target: 0)).to be_nil
      expect(plan(target: -1)).to be_nil
    end

    it "never hands back a bitrate below the floor it set itself" do
      expect(described_class::MIN_VIDEO_BITRATE).to be_positive

      [1, 5, 10, 25, 50].each do |mb|
        [15, 60, 300, 1800, 5400].each do |seconds|
          result = plan(target: mb * MB, duration: seconds, height: 1080, width: 1920)
          next if result.nil?

          expect(result.video_bitrate).to be >= described_class::MIN_VIDEO_BITRATE
          expect(result.video_bitrate).to be >= described_class.floor_for(result.height)
        end
      end
    end

    # The point of the whole sum: whatever it hands back, the arithmetic says
    # the file lands under the ceiling.
    it "always plans a file that fits, across a spread of sizes and lengths" do
      [5, 10, 25, 50, 100].each do |mb|
        [10, 45, 120, 600, 1800].each do |seconds|
          result = plan(target: mb * MB, duration: seconds, height: 1080, width: 1920)
          next if result.nil?

          expect(result.total_bitrate * seconds / 8).to be <= mb * MB
        end
      end
    end
  end
end
