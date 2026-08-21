# frozen_string_literal: true

module Tina4Ultipa
  # A gqldb server or protocol error. Writes and bad statements fail LOUD (raise),
  # never a falsy return - the framework's graph layer relies on this.
  # `code` is the gRPC status name when known.
  class Error < StandardError
    attr_reader :code

    def initialize(message, code: nil, cause: nil)
      super(message)
      @code = code
      @cause_error = cause
    end

    # The wrapped lower-level exception (gRPC error), when there is one.
    attr_reader :cause_error
  end

  # Could not connect within the timeout. Names host, port and elapsed seconds.
  class ConnectError < Error
    attr_reader :host, :port, :elapsed

    def initialize(host, port, elapsed, cause: nil)
      super(
        "could not connect to ultipa at #{host}:#{port} within #{format('%.2f', elapsed)}s",
        code: "UNAVAILABLE",
        cause: cause,
      )
      @host = host
      @port = port
      @elapsed = elapsed
    end
  end
end
