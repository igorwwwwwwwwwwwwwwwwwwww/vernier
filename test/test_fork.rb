# frozen_string_literal: true

require "test_helper"
require "active_support"

class TestFork < Minitest::Test
  def test_forked_children_exit
    Vernier.profile(interval: 500) do
      10.times do
        assert_child_exits(fork { sleep 0.01 })
      end
    end
  end

  def test_parent_samples_before_and_after_fork
    collector = Vernier::Collector.new(:wall, interval: 1_000)
    collector.start
    busy(0.05); before_line = __LINE__
    before_fork = collector.current_time
    assert_child_exits(fork { sleep 0.01 })
    after_fork = collector.current_time
    busy(0.05); after_line = __LINE__
    result = collector.stop

    assert_valid_result result
    lines = sampled_lines(result, __method__)
    assert_includes lines, before_line
    assert_includes lines, after_line
    timestamps = result.main_thread[:timestamps]
    assert_operator timestamps.min, :<, before_fork
    assert_operator timestamps.max, :>, after_fork
  end

  def test_fork_from_another_thread
    result = Vernier.profile(interval: 500) do
      Thread.new { assert_child_exits(fork { sleep 0.01 }) }.join
      busy(0.02)
    end

    assert_valid_result result
    refute_empty result.main_thread[:samples]
  end

  def test_fork_with_other_threads
    done = false
    threads = 4.times.map do
      Thread.new do
        sleep 0.001 until done
      end
    end

    result = Vernier.profile(interval: 500) do
      10.times do
        assert_child_exits(fork { sleep 0.01 })
      end
    end
    assert_valid_result result
  ensure
    done = true
    threads.each(&:join)
  end

  def test_forks_from_two_threads
    result = Vernier.profile(interval: 500) do
      2.times.map do
        Thread.new do
          5.times { assert_child_exits(fork { sleep 0.01 }) }
        end
      end.each(&:join)
    end
    assert_valid_result result
  end

  def test_collectors_started_during_forks
    done = false
    starter = Thread.new do
      Vernier.profile(interval: 500) { sleep 0.001 } until done
    end

    20.times do
      assert_child_exits(fork { sleep 0.01 })
    end
  ensure
    done = true
    starter.join
  end

  def test_child_forks_again
    Vernier.profile(interval: 500) do
      pid = fork do
        status = wait_for_child(fork { sleep 0.01 })
        exit!(status&.success? ? 0 : 1)
      end
      assert_child_exits(pid)
    end
  end

  def test_two_collectors
    outer = inner = nil
    outer = Vernier.profile(interval: 500) do
      inner = Vernier.profile(interval: 500) do
        assert_child_exits(fork { sleep 0.01 })
        busy(0.02)
      end
      busy(0.02)
    end

    assert_valid_result outer
    assert_valid_result inner
    refute_empty inner.main_thread[:samples]
    assert_operator outer.main_thread[:weights].sum, :>, inner.main_thread[:weights].sum
  end

  def test_start_profile_and_stop_profile
    Vernier.start_profile(interval: 500)
    assert_child_exits(fork { sleep 0.01 })
    busy(0.02)
    result = Vernier.stop_profile

    assert_valid_result result
    refute_empty result.main_thread[:samples]
  end

  def test_child_has_no_profile
    collector = Vernier::Collector.new(:wall, interval: 500, hooks: [:activesupport])
    collector.start
    pid = fork do
      ok = !collector.running? &&
        collector.stop.nil? &&
        !ActiveSupport::Notifications.notifier.listening?("sql.active_record")
      exit!(ok ? 0 : 1)
    end
    assert_child_exits(pid)

    assert_predicate collector, :running?
    assert ActiveSupport::Notifications.notifier.listening?("sql.active_record")
    assert_valid_result collector.stop
  end

  def test_fork_without_a_block
    result = Vernier.profile(interval: 500) do
      pid = fork
      exit unless pid
      assert_child_exits(pid)
    end
    assert_valid_result result
  end

  def test_stop_profile_in_child
    Vernier.start_profile(interval: 500)
    pid = fork do
      Vernier.stop_profile
      exit!(1)
    rescue RuntimeError => e
      exit!(e.message == "profile not started" ? 0 : 1)
    end
    assert_child_exits(pid)
  ensure
    Vernier.stop_profile
  end

  def test_start_profile_in_child
    Vernier.start_profile(interval: 500)
    busy(0.02)
    before_fork = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    pid = fork do
      Vernier.start_profile(interval: 500)
      busy(0.02)
      thread = Vernier.stop_profile.main_thread
      exit!(!thread[:samples].empty? && thread[:timestamps].min > before_fork ? 0 : 1)
    end
    assert_child_exits(pid)
  ensure
    Vernier.stop_profile
  end

  def test_paused_collector_stays_paused
    collector = Vernier::Collector.new(:wall, interval: 500)
    collector.start
    busy(0.02); before_line = __LINE__
    collector.pause
    assert_child_exits(fork { sleep 0.01 })
    busy(0.02); after_line = __LINE__

    refute_predicate collector, :running?
    result = collector.stop
    assert_valid_result result
    lines = sampled_lines(result, __method__)
    assert_includes lines, before_line
    refute_includes lines, after_line
  end

  def test_retained_collector
    retained = []
    result = Vernier.profile(mode: :retained) do
      retained << Object.new
      assert_child_exits(fork { sleep 0.01 })
      retained << Object.new
    end

    assert_valid_result result
    assert_operator result.total_bytes, :>, 0
  end

  def test_custom_collector
    collector = Vernier::Collector.new(:custom)
    collector.start
    collector.sample
    assert_child_exits(fork { sleep 0.01 })
    collector.sample
    result = collector.stop

    assert_valid_result result
    assert_equal 2, result.total_weights
  end

  def test_memory_usage_hook
    after_fork = nil
    result = Vernier.profile(interval: 500, hooks: [:memory_usage]) do |collector|
      assert_child_exits(fork { sleep 0.01 })
      after_fork = collector.current_time
      sleep 0.05
    end

    assert_valid_result result
    timestamps = result.hooks.first.firefox_counters[:samples][:time]
    assert_operator timestamps.max, :>, after_fork / 1_000_000.0
  end

  def test_memory_tracker
    tracker = Vernier::MemoryTracker.new
    tracker.start
    assert_child_exits(fork { sleep 0.01 })
    after_fork = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    sleep 0.05

    timestamps, = tracker.results
    assert_operator timestamps.max, :>, after_fork
  ensure
    tracker.stop
  end

  def test_memory_tracker_in_child
    tracker = Vernier::MemoryTracker.new
    tracker.start
    pid = fork do
      in_child = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      sleep 0.05
      timestamps, = tracker.results
      exit(timestamps.max > in_child)
    end
    assert_child_exits(pid)
  ensure
    tracker.stop
  end

  private

  def assert_child_exits(pid)
    status = wait_for_child(pid)
    refute_nil status, "forked child did not exit"
    assert_predicate status, :success?
  end

  # A child that waits for a lock it inherited never exits. Kill it instead of
  # blocking the suite.
  def wait_for_child(pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill(:KILL, pid)
        Process.wait(pid)
        return nil
      end
      sleep 0.005
    end
  end

  # The lines of the test method that the main thread was sampled in
  def sampled_lines(result, test_method)
    result.main_thread[:samples].map do |stack_idx|
      result.stack(stack_idx).frames.detect { _1.name.end_with?(test_method.to_s) }&.line
    end
  end

  def busy(seconds)
    target = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < target
  end
end
