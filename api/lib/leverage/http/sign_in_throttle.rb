module Leverage
  module Http
    # Counts wrong passwords (PRD, Security). The owner's password is the
    # only thing between a program that can reach the Mac's loopback
    # address and the owner's session, and a guess costs the caller
    # nothing. After LIMIT wrong passwords inside WINDOW seconds no
    # password is compared until the oldest of them is WINDOW seconds old.
    #
    #   user = Leverage::Http::SignInThrottle.check { User.authenticate_by(...) }
    #
    # One count for the whole server, kept in this process: there is one
    # owner, every caller arrives on the same loopback address, and the
    # server is one Puma process (config/puma.rb starts no workers). A
    # restart clears it. A check in progress holds a place, so the threads
    # of the pool cannot each try a password at the same moment. Only a
    # wrong password is counted: a right one, and a check that raised, are
    # not. The cost is that a program on the Mac can keep sign-in refused
    # by sending wrong passwords; a session that is already open has no
    # expiry and keeps working.
    module SignInThrottle
      LIMIT = 10
      WINDOW = 60

      # Too many wrong passwords: 401 unauthenticated (ApplicationController).
      class Blocked < StandardError
        def initialize(message = "Too many wrong sign-ins. Wait a minute and try again") = super
      end

      @mutex = Mutex.new
      @failures = []
      @checking = 0

      module_function

      # Runs the block, which compares a password and answers who it signs
      # in, or nil, and answers what the block answers. Raises Blocked,
      # without running the block, when LIMIT wrong passwords and checks in
      # progress are already counted.
      def check(clock: method(:wall_clock))
        enter(clock.call)
        wrong = false
        begin
          found = yield
          wrong = found.nil?
          found
        ensure
          leave(wrong ? clock.call : nil)
        end
      end

      # Forgets every count (the tests, which share one process).
      def reset!
        @mutex.synchronize do
          @failures = []
          @checking = 0
        end
      end

      # The wall clock, so that a test can move it (travel). A wrong
      # password dated after now, which a clock that stepped back leaves
      # behind, is dropped with the old ones.
      def wall_clock = Time.current.to_f

      def enter(now)
        @mutex.synchronize do
          @failures.select! { |at| at <= now && at > now - WINDOW }
          raise Blocked if @failures.size + @checking >= LIMIT

          @checking += 1
        end
      end

      def leave(failed_at)
        @mutex.synchronize do
          @checking -= 1 if @checking.positive?
          @failures << failed_at if failed_at
        end
      end
      private_class_method :enter, :leave
    end
  end
end
