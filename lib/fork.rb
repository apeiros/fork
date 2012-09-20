# encoding: utf-8



require 'fork/version'



# An object representing a fork, containing data about it like pid, exit_status,
# exception etc.
#
# It also provides facilities for parent and child process to communicate
# with each other.
#
# @example Usage
#     def fib(n) n < 2 ? n : fib(n-1)+fib(n-2); end # <-- bad implementation of fibonacci
#     fork = Fork.new :return do
#       fib(35)
#     end
#     fork.execute
#     puts "Forked child process with pid #{fork.pid} is currently #{fork.alive? ? 'alive' : 'dead'}"
#     puts fork.return_value # this blocks, until the fork finished, and returns the last value
#
# @example The same, but a bit simpler
#     def fib(n) n < 2 ? n : fib(n-1)+fib(n-2); end # <-- bad implementation of fibonacci
#     fork = Fork.execute :return do
#       fib(35)
#     end
#     puts fork.return_value # this blocks, until the fork finished, and returns the last value
#
# @example And the simplest version, if all you care about is the return value
#     def fib(n) n < 2 ? n : fib(n-1)+fib(n-2); end # <-- bad implementation of fibonacci
#     future = Fork.future do
#       fib(35)
#     end
#     puts future.call # this blocks, until the fork finished, and returns the last value
#
# @note
#   You should only interact between parent and fork by the means provided by the Fork
#   class.
class Fork

  # Exceptions that have to be ignored in the child's handling of exceptions
  IgnoreExceptions = [::SystemExit]

  # Raised when a fork raises an exception that can't be dumped
  # This is the case if the exception is either an anonymous class or
  # contains undumpable data (anonymous ancestor, added state, …)
  class UndumpableException < StandardError; end

  # Raised when you try to do something which would have required creating
  # the fork instance with a specific flag which wasn't provided.
  class FlagNotSpecified < StandardError; end

  # Raised when you try to write to/read from a fork which is not running yet or not
  # anymore.
  class NotRunning < StandardError; end

  # The default flags Fork#initialize uses
  DefaultFlags = Hash.new { |_hash, key| raise ArgumentError, "Unknown flag #{key}" }.merge({
    :exceptions   => false,
    :death_notice => false,
    :return       => false,
    :to_fork      => false,
    :from_fork    => false,
    :ctrl         => false,
  })

  # Reads an object sent via Fork.read_marshalled from the passed io.
  # Raises EOFError if the io was closed on the remote end.
  #
  # @return [Object] The deserialized object which was sent through the IO
  #
  # @see Fork.write_marshalled Implements the opposite operation: writing an object on an IO.
  def self.read_marshalled(io)
    size       = io.read(4)
    raise EOFError unless size
    size       = size.unpack("I").first
    marshalled = io.read(size)
    Marshal.load(marshalled)
  end

  # Writes an object in serialized form to the passed IO.
  # Important: certain objects are not marshallable, e.g. IOs, Procs and
  # anonymous modules and classes.
  #
  # @return [Integer] The number of bytes written to the IO (see IO#write)
  #
  # @see Fork.read_marshalled Implements the opposite operation: writing an object on an IO.
  def self.write_marshalled(io, obj)
    marshalled = Marshal.dump(obj)
    io.write([marshalled.size].pack("I"))
    io.write(marshalled)
  end

  # A simple forked-future implementation. Will process the block in a fork,
  # blocks upon request of the result until the result is present.
  # If the forked code raises an exception, invoking call on the proc will raise that
  # exception in the parent process.
  #
  # @param args
  #   All parameters passed to Fork.future are passed on to the block.
  #
  # @return [Proc]
  #   A lambda which upon invoking #call will block until the result of the block is
  #   calculated.
  #
  # @example Usage
  #     # A
  #     Fork.future { 1 }.call # => 1
  #     
  #     # B
  #     result = Fork.future { sleep 2; 1 } # assume a complex computation instead of sleep(2)
  #     sleep 2                             # assume another complex computation
  #     start  = Time.now
  #     result.call                         # => 1
  #     elapsed_time = Time.now-start       # => <1s as the work was done parallely
  def self.future(*args)
    obj = execute :return => true do |parent|
      yield(*args)
    end

    lambda { obj.return_value }
  end

  # A simple forked-callback implementation. Will process the block in a fork,
  # block until it has finished processing and returns the return value of the
  # block.
  # This can be useful if you want to process something that will (or might)
  # irreversibly corrupt the environment. Doing that in a subprocess will leave
  # the parent untouched.
  #
  # @param args
  #   All parameters passed to Fork.return are passed on to the block.
  #
  # @return
  #   Returns the result of the block.
  #
  # @example Usage
  #     Fork.return { 1 } # => 1
  def self.return(*args)
    obj = execute :return => true do |parent|
      yield(*args)
    end
    obj.return_value
  end

  # Create a Fork instance and immediatly start executing it.
  # Equivalent to just call Fork.new(*args) { ... }.execute
  #
  # Returns the Fork instance.
  # See Fork#initialize
  def self.execute(*args, &block)
    new(*args, &block).execute
  end

  # The process id of the fork
  #
  # @note
  #   You *must not* directly interact with the forked process using the pid.
  #   This may lead to unexpected conflicts with Fork's internal mechanisms.
  attr_reader :pid

  # Readable IO
  # Allows the parent to read data from the fork, and the fork to read data from the
  # parent.
  # Requires the :to_fork and/or :from_fork flag to be set.
  attr_reader :readable_io

  # Writable IO
  # Allows the parent to write data to the fork, and the fork to write data to the parent.
  # Requires the :to_fork and/or :from_fork flag to be set.
  attr_reader :writable_io

  # Control IO (reserved for exception and death-notice passing)
  attr_reader :ctrl

  # Create a new Fork instance.
  # @param [Symbol, Hash] flags
  #   Tells the fork what facilities to provide. You can pass the flags either as a list
  #   of symbols, or as a Hash, or even mixed (the hash must be the last argument then).
  #
  #   Valid flags are:
  #   * :return       Make the value of the last expression (return value) available to
  #                   the parent process
  #   * :exceptions   Pass exceptions of the fork to the parent, making it available via
  #                   Fork#exception
  #   * :death_notice Send the parent process an information when done processing
  #   * :to_fork      You can write to the Fork from the parent process, and read in the
  #                   child process
  #   * :from_fork    You can read from the Fork in the parent process and write in the
  #                   child process
  #   * :ctrl         Provides an additional IO for control mechanisms
  #
  #   Some flags implicitly set other flags. For example, :return will set :exceptions and
  #   :ctrl, :exceptions will set :ctrl and :death_notice will also set :ctrl.
  #
  # The subprocess is not immediatly executed, you must invoke #execute on the Fork
  # instance in order to get it executed. Only then #pid, #in, #out and #ctrl will be
  # available. Also all IO related methods won't work before that.
  def initialize(*flags, &block)
    raise ArgumentError, "No block given" unless block
    if flags.last.is_a?(Hash) then
      @flags = DefaultFlags.merge(flags.pop)
    else
      @flags = DefaultFlags.dup
    end
    flags.each do |flag|
      raise ArgumentError, "Unknown flag #{flag.inspect}" unless @flags.has_key?(flag)
      @flags[flag] = true
    end
    @flags[:ctrl]       = true if @flags.values_at(:exceptions, :death_notice, :return).any?
    @flags[:exceptions] = true if @flags[:return]

    @parent         = true
    @alive          = nil
    @pid            = nil
    @process_status = nil
    @readable_io    = nil
    @writable_io    = nil
    @ctrl           = nil
    @block          = block
  end

  # Creates the fork (subprocess) and starts executing it.
  #
  # @return [self]
  def execute
    ctrl_read, ctrl_write, fork_read, parent_write, parent_read, fork_write = nil

    fork_read, parent_write = binary_pipe if @flags[:to_fork]
    parent_read, fork_write = binary_pipe if @flags[:from_fork]
    ctrl_read, ctrl_write   = binary_pipe if @flags[:ctrl]

    @alive = true

    pid = Process.fork do
      @parent = false
      parent_write.close if parent_write
      parent_read.close  if parent_read
      ctrl_read.close    if ctrl_read
      complete!(Process.pid, fork_read, fork_write, ctrl_write)

      child_process
    end

    fork_write.close if fork_write
    fork_read.close  if fork_read
    ctrl_write.close if ctrl_write
    complete!(pid, parent_read, parent_write, ctrl_read)

    self
  end

  # @return [Boolean] Whether this fork sends the final exception to the parent
  def handle_exceptions?
    @flags[:exceptions]
  end

  # @return [Boolean] Whether this fork sends a death notice to the parent
  def death_notice?
    @flags[:death_notice]
  end

  # @return [Boolean] Whether this forks terminal value is returned to the parent
  def returns?
    @flags[:return]
  end

  # @return [Boolean] Whether the other process can write to this process.
  def has_in?
    @flags[parent? ? :from_fork : :to_fork]
  end

  # @return [Boolean] Whether this process can write to the other process.
  def has_out?
    @flags[parent? ? :to_fork : :from_fork]
  end

  # @return [Boolean] Whether parent and fork use a control-io.
  def has_ctrl?
    @flags[:ctrl]
  end

  # @return [Boolean]
  #   Whether the current code is executed in the parent of the fork.
  def parent?
    @parent
  end

  # @return [Boolean]
  #   Whether the current code is executed in the fork, as opposed to the parent.
  def fork?
    !@parent
  end

  # Sets the io to communicate with the parent/child
  def complete!(pid, readable_io, writable_io, ctrl_io) # :nodoc:
    raise "Can't call complete! more than once" if @pid
    @pid          = pid
    @readable_io  = readable_io
    @writable_io  = writable_io
    @ctrl         = ctrl_io
  end

  # Process::Status for dead forks, nil for live forks
  def process_status(blocking=true)
    @process_status || begin
      _wait(blocking)
      @process_status
    end
  end

  # The exit status of this fork.
  # See Process::Status#exitstatus
  def exit_status(blocking=true)
    @exit_status || begin
      _wait(blocking)
      @exit_status
    rescue NotRunning
      raise if blocking # calling exit status on a not-yet started fork is an exception, nil otherwise
    end
  end

  # Blocks until the fork has exited.
  #
  # @return [Boolean]
  #   Whether the fork exited with a successful exit status (status code 0).
  def success?
    exit_status.zero?
  end

  # Blocks until the fork has exited.
  #
  # @return [Boolean]
  #   Whether the fork exited with an unsuccessful exit status (status code != 0).
  def failure?
    !success?
  end

  # The exception that terminated the fork
  # Requires the :exceptions flag to be set when creating the fork.
  def exception(blocking=true)
    @exception || begin
      raise FlagNotSpecified, "You must set the :exceptions flag when forking in order to use this" unless handle_exceptions?
      _wait(blocking)
      @exception
    end
  end

  # Blocks until the fork returns 
  def return_value(blocking=true)
    @return_value || begin
      raise FlagNotSpecified, "You must set the :return flag when forking in order to use this" unless returns?
      _wait(blocking)
      raise @exception if @exception
      @return_value
    end
  end

  # Whether this fork is still running (= is alive) or already exited.
  def alive?
    @pid && !exit_status(false)
  end

  # Whether this fork is still running or already exited (= is dead).
  def dead?
    !alive?
  end

  # In the parent process: read data from the fork.
  # In the forked process: read data from the parent.
  # Works just like IO#gets.
  #
  # @return [String, nil] The data that the forked/parent process has written.
  def gets(*args)
    @readable_io.gets(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :to_fork flag when forking in order to use this" unless @readable_io
    raise
  end

  # In the parent process: read data from the fork.
  # In the forked process: read data from the parent.
  # Works just like IO#read.
  #
  # @return [String, nil] The data that the forked/parent process has written.
  def read(*args)
    @readable_io.read(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :to_fork flag when forking in order to use this" unless @readable_io
    raise
  end

  # In the parent process: read data from the fork.
  # In the forked process: read data from the parent.
  # Works just like IO#read_nonblock.
  #
  # @return [String, nil] The data that the forked/parent process has written.
  def read_nonblock(*args)
    @readable_io.read_nonblock(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :to_fork flag when forking in order to use this" unless @readable_io
    raise
  end

  # In the parent process: read on object sent by the fork.
  # In the forked process: read on object sent by the parent.
  #
  # @return [Object] The object that the forked/parent process has sent.
  #
  # @see Fork#send_object An example can be found in the docs of Fork#send_object.
  def receive_object
    Fork.read_marshalled(@readable_io)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :from_fork flag when forking in order to use this" unless @readable_io
    raise
  end

  # In the parent process: Write to the fork.
  # In the forked process: Write to the parent.
  # Works just like IO#puts
  #
  # @return [nil]
  def puts(*args)
    @writable_io.puts(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :from_fork flag when forking in order to use this" unless @writable_io
    raise
  end

  # In the parent process: Write to the fork.
  # In the forked process: Write to the parent.
  # Works just like IO#write
  #
  # @return [Integer] The number of bytes written
  def write(*args)
    @writable_io.write(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :from_fork flag when forking in order to use this" unless @writable_io
    raise
  end

  # Read a single instruction sent via @ctrl, used by :exception, :death_notice and
  # :return_value
  #
  # @return [self]
  def read_remaining_ctrl(_wait_upon_eof=true) # :nodoc:
    loop do # EOFError will terminate this loop
      instruction, data = *Fork.read_marshalled(@ctrl)
      case instruction
        when :exception
          @exception = data
        when :death_notice
          _wait if _wait_upon_eof
          _wait_upon_eof = false
        when :return_value
          @return_value = data
        else
          raise "Unknown control instruction #{instruction} in fork #{fork}"
      end
    end

    self
  rescue EOFError # closed
    _wait(false) if _wait_upon_eof # update

    self
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :ctrl flag when forking in order to use this" unless @ctrl
    raise
  end

  # Sends an object to the parent process.
  # The parent process can read it using Fork#receive_object.
  #
  # @example Usage
  #     Demo = Struct.new(:a, :b, :c)
  #     fork = Fork.new :from_fork do |parent|
  #       parent.send_object({:a => 'little', :nested => ['hash']})
  #       parent.send_object(Demo.new(1, :two, "three"))
  #     end
  #     p :received => fork.receive_object # -> {:received=>{:a=>"little", :nested=>["hash"]}}
  #     p :received => fork.receive_object # -> {:received=>#<struct Demo a=1, b=:two, c="three">}
  #
  # @see Fork#receive_object Fork#receive_object implements the opposite.
  def send_object(obj)
    Fork.write_marshalled(@writable_io, obj)
    self
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :from_fork flag when forking in order to use this" unless @writable_io
    raise
  end

  # Wait for this fork to terminate.
  # Returns self
  #
  # @example Usage
  #     start = Time.now
  #     fork = Fork.new do sleep 20 end
  #     fork.wait
  #     (Time.now-start).floor # => 20
  def wait
    _wait unless @process_status
    self
  end

  # Sends the (SIG)HUP signal to this fork.
  # This is "gently asking the process to terminate".
  # This gives the process a chance to perform some cleanup.
  # See Fork#kill!, Fork#signal, Process.kill
  def kill
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill("HUP", @pid)
  end

  # Sends the (SIG)KILL signal to this fork.
  # The process will be immediatly terminated and will not have a chance to
  # do any cleanup.
  # See Fork#kill, Fork#signal, Process.kill
  def kill!
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill("KILL", @pid)
  end

  # Sends the given signal to this fork
  # See Fork#kill, Fork#kill!, Process.kill
  def signal(sig)
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill(sig, @pid)
  end

  # Close all IOs
  def close # :nodoc:
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    @readable_io.close if @readable_io
    @writable_io.close if @writable_io
    @ctrl.close if @ctrl
  end

  # @private
  # Duping a fork instance is prohibited. See Object#dup.
  def dup # :nodoc:
    raise TypeError, "can't dup #{self.class}"
  end

  # @private
  # Cloning a fork instance is prohibited. See Object#clone.
  def clone # :nodoc:
    raise TypeError, "can't clone #{self.class}"
  end

  # @private
  # See Object#inspect
  def inspect # :nodoc:
    sprintf "#<%p pid=%p alive=%p>", self.class, @pid, @alive
  end

private
  # @private
  # Work around issues in 1.9.3-p194 (it has difficulties with the encoding settings of
  # the pipes).
  #
  # @return [Array<IO>]
  #   Returns a pair of IO instances, just like IO::pipe. The IO's encoding is set to
  #   binary.
  def binary_pipe
    if defined?(Encoding::BINARY)
      in_io, out_io = IO.pipe(Encoding::BINARY)
      in_io.set_encoding(Encoding::BINARY)
      out_io.set_encoding(Encoding::BINARY)
      [in_io, out_io]
    else
      IO.pipe
    end
  end

  # @private
  # Internal wait method that waits for the forked process to exit and collects
  # information when the process exits.
  #
  # @param [Boolean] blocking
  #   If blocking is true, the method blocks until the fork exits, otherwise it
  #   will return immediately.
  #
  # @return [self]
  def _wait(blocking=true)
    raise NotRunning unless @pid

    _, status = *Process.wait2(@pid, blocking ? 0 : Process::WNOHANG)
    if status then
      @process_status = status
      @exit_status    = status.exitstatus
      read_remaining_ctrl if has_ctrl?
    end
  rescue Errno::ECHILD # can happen if the process is already collected
    raise "Can't determine exit status of #{self}, make sure to not interfere with process handling externally" unless @process_status
    self
  end

  # @private
  #
  # Embedds the forked code into everything needed to handle return value, exceptions,
  # cleanup etc.
  def child_process
    return_value = @block.call(self)
    Fork.write_marshalled(@ctrl, [:return_value, return_value]) if returns?
  rescue *IgnoreExceptions
    raise # reraise ignored exceptions as-is
  rescue Exception => e
    $stdout.puts "Exception in child #{$$}: #{e}", *e.backtrace.first(5)
    if handle_exceptions?
      begin
        Fork.write_marshalled(@ctrl, [:exception, e])
      rescue TypeError # dumping the exception was not possible, try to extract as much information as possible
        class_name = String(e.class.name) rescue "<<Unable to extract classname>>"
        class_name = "<<No classname>>" if class_name.empty?
        message    = String(e.message) rescue "<<Unable to extract message>>"
        backtrace  = Array(e.backtrace).map { |line| String(line) rescue "<<bogus backtrace-line>>" } rescue ["<<Unable to extract backtrace>>"]
        rewritten  = UndumpableException.new("Could not send original exception to parent. Original exception #{class_name}: '#{message}'")
        rewritten.set_backtrace backtrace
        Fork.write_marshalled(@ctrl, [:exception, rewritten])
      rescue Exception
        # Something entirely unexpceted happened, ensure at least that we exit with status 1
      end
    end
    exit! 1
  ensure
    Fork.write_marshalled(@ctrl, [:death_notice]) if death_notice?
    close
  end
end
