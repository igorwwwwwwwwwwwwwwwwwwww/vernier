# frozen_string_literal: true

module Vernier
  # A child forked while a collector samples can inherit a lock that the
  # sampling thread or another thread's event hook holds, and then waits for
  # it forever. So collectors don't sample while the process forks, and the
  # child has no profile running.
  #
  # fork, Kernel#fork and IO.popen("-") all call Process._fork.
  module ForkHooks
    def _fork
      # Collectors only exist in the main Ractor
      return super unless Ractor.current == Ractor.main

      parent = Process.pid
      Collector.fork_started
      begin
        super
      ensure
        in_child = Process.pid != parent
        Vernier.cancel_inherited_profiles if in_child
        Collector.fork_finished(in_child)
      end
    end
  end

  ::Process.singleton_class.prepend(ForkHooks)
end
