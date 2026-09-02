require "json"
require "./scenario"

# Shared measurement harness. Everything a bench binary needs that is not
# specific to the library under test.
module Bench
  # Run configuration, read from the environment so every implementation
  # takes exactly the same knobs.
  struct Config
    getter scenario : Scenario::Kind
    getter target_fps : Int32
    getter frames : Int32
    getter impl : String
    getter variant : String

    def initialize(@impl : String)
      @scenario = Scenario.parse_kind(ENV["BENCH_SCENARIO"]? || "churn")
      @target_fps = (ENV["BENCH_TARGET_FPS"]? || "60").to_i
      @frames = (ENV["BENCH_FRAMES"]? || "300").to_i
      @variant = ENV["BENCH_VARIANT"]? || "default"
    end

    def frame_interval : Time::Span
      (1.0 / target_fps).seconds
    end

    def scenario_name : String
      scenario.to_s.downcase
    end
  end

  # Collects per-frame timings without allocating on the hot path: the sample
  # array is sized up front, and nothing is formatted or logged until the run
  # is over.
  class FrameStats
    getter samples : Array(Float64)
    getter missed_ticks = 0_u64
    @start : Time::Instant?
    @frame_start : Time::Instant?

    def initialize(capacity : Int32)
      @samples = Array(Float64).new(capacity)
    end

    def begin_run : Nil
      @start = Time.instant
    end

    def frame_begin : Nil
      @frame_start = Time.instant
    end

    # Records the frame that started at the last `frame_begin`.
    def frame_end : Nil
      if fs = @frame_start
        @samples << (Time.instant - fs).total_milliseconds
      end
    end

    def record_missed(n : UInt64) : Nil
      @missed_ticks += n
    end

    def wall_seconds : Float64
      if s = @start
        (Time.instant - s).total_seconds
      else
        0.0
      end
    end

    private def percentile(sorted : Array(Float64), p : Float64) : Float64
      return 0.0 if sorted.empty?
      idx = ((sorted.size - 1) * p).round.to_i
      sorted.unsafe_fetch(idx)
    end

    # Emits one JSON line on STDERR. STDOUT is reserved for the terminal
    # output stream, which the runner counts to get bytes-per-frame.
    def report(config : Config, extra = {} of String => JSON::Any::Type) : Nil
      sorted = @samples.sort
      wall = wall_seconds
      data = {
        "impl"          => config.impl,
        "variant"       => config.variant,
        "scenario"      => config.scenario_name,
        "target_fps"    => config.target_fps,
        "frames"        => @samples.size,
        "wall_s"        => wall,
        "achieved_fps"  => wall > 0 ? @samples.size / wall : 0.0,
        "frame_ms_p50"  => percentile(sorted, 0.50),
        "frame_ms_p95"  => percentile(sorted, 0.95),
        "frame_ms_p99"  => percentile(sorted, 0.99),
        "frame_ms_mean" => @samples.empty? ? 0.0 : @samples.sum / @samples.size,
        "missed_ticks"  => @missed_ticks,
      }
      merged = {} of String => JSON::Any
      data.each { |k, v| merged[k] = JSON.parse(v.to_json) }
      extra.each { |k, v| merged[k] = JSON.parse(v.to_json) }
      STDERR.puts merged.to_json
      STDERR.flush
    end
  end
end
