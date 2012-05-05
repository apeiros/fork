# encoding: utf-8

# An object representing a fork, containing data about it like pid, name, 
# exit_status, exception etc.
# It also provides facilities for parent and child process to communicate
# with each other.
class Fork
  # Exceptions that have to be ignored in the child's handling of exceptions
  IgnoreExceptions = [::SystemExit]

  # Raised when a fork raises an exception that can't be dumped
  # This is the case if the exception is either an anonymous class or
  # contains undumpable data (anonymous ancestor, added state, ...)
  class UndumpableException < StandardError; end

  # Raised when you try to do something which would have required creating
  # the fork instance with a specific flag which wasn't provided.
  class FlagNotSpecified < StandardError; end

  class NotRunning < StandardError; end

  # Reads an object sent via Fork::read_marshalled from the passed io.
  # Raises EOFError if the io was closed on the remote end.
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
  # See Fork::read_marshalled
  def self.write_marshalled(io, obj)
    marshalled = Marshal.dump(obj)
    io.write([marshalled.size].pack("I"))
    io.write(marshalled)
  end

  # A simple forked-future implementation. Will process the block in a fork,
  # blocks upon request of the result until the result is present.
  #
  # Example:
  #   # A
  #   Fork.future { 1 }.call # => 1
  #   
  #   # B
  #   result = Fork.future { sleep 2; 1 } # assume a complex computation instead of sleep(2)
  #   sleep 2                             # assume another complex computation
  #   start  = Time.now
  #   result.call                         # => 1
  #   elapsed_time = Time.now-start       # => <1s as the work was done parallely
  def self.future(*args)
    obj = execute nil, :return do |parent|
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
  # Example:
  #   pool.return { 1 } # => 1
  def self.return(*args)
    obj = execute nil, :return do |parent|
      yield(*args)
    end
    obj.return_value
  end

  # Create a Fork instance and immediatly start executing it.
  # Equivalent to just call Fork.new(*args) { ... }.execute
  #
  # Returns the Fork instance.
  # See Fork::new
  def self.execute(*args, &block)
    new(*args, &block).execute
  end

  # The process id of the fork
  # You MUST NOT directly interact with the forked process using the pid!
  # This may lead to unexpected conflicts with Fork's internal mechanisms.
  attr_reader :pid

  # The name of the fork (see ForkPool#fork's options)
  attr_reader :name

  # Readable IO
  attr_reader :in

  # Writable IO
  attr_reader :out

  # Control IO (reserved for exception and death-notice passing)
  attr_reader :ctrl

  # Create a new Fork instance.
  # Name is an optional name (pass nil if you don't want the fork to be named),
  # must be a Symbol.
  # Flags tells the fork what facilities to provide. Valid flags:
  # * :exceptions::   Pass exceptions of the fork to the parent, making it available via Fork#exception
  # * :death_notice:: Send the parent process an information when done processing
  # * :in::           You can write to the Fork from the parent process, and read in the child process
  # * :out::          You can read from the Fork in the parent process and write in the child process
  # * :ctrl::         Set by :exceptions and :death_notice - provides an additional IO for control mechanisms
  #
  # The subprocess is not immediatly executed, you must invoke #execute on the Fork instance in order to get it
  # executed. Only then #pid, #in, #out and #ctrl will be available. Also all IO related methods won't work before that.
  def initialize(name=nil, *flags, &block)
    @handle_exceptions = !!flags.delete(:exceptions)
    @death_notice      = !!flags.delete(:death_notice)
    @returns           = !!flags.delete(:return)
    @handle_exceptions = true if @returns # return requires exceptions
    flags             << :ctrl if (@handle_exceptions || @death_notice || @returns) && !flags.include?(:ctrl)

    raise ArgumentError, "Unknown flags: #{flags.join(', ')}" unless (flags-[:in, :out, :ctrl]).empty?
    raise ArgumentError, "No block given" unless block

    @flags             = flags
    @name              = name
    @alive             = nil
    @pid               = nil
    @process_status    = nil
    @in                = nil
    @out               = nil
    @ctrl              = nil
    @block             = block
  end

  # Start executing the subprocess.
  def execute
    ctrl_read, ctrl_write, fork_read, parent_write, parent_read, fork_write = nil

    fork_read, parent_write = IO.pipe if @flags.include?(:in)
    parent_read, fork_write = IO.pipe if @flags.include?(:out)
    ctrl_read, ctrl_write   = IO.pipe if @flags.include?(:ctrl)

    @alive = true

    pid = Process.fork do
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

  # Whether this fork sends the final exception to the parent
  # See Fork#exception
  def handle_exceptions?
    @handle_exceptions
  end

  # Whether this fork sends a death notice to the parent
  def death_notice?
    @death_notice
  end

  # Whether this forks terminal value is returned to the parent
  def returns?
    @returns
  end

  # Sets the name and io to communicate with the parent/child
  def complete!(pid, readable_io, writable_io, ctrl_io) # :nodoc:
    raise "Can't call complete! more than once" if @pid
    @pid  = pid
    @in   = readable_io
    @out  = writable_io
    @ctrl = ctrl_io
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
    end
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
    raise @exception if exception()
    @return_value || begin
      raise FlagNotSpecified, "You must set the :return flag when forking in order to use this" unless returns?
      _wait(blocking)
      raise @exception if @exception
      @return_value
    end
  end

  # Whether this fork is still running (= is alive) or already exited.
  def alive?
    !exit_status
  end

  # Whether this fork is still running or already exited (= is dead).
  def dead?
    !!exit_status
  end

  # Read from the fork.
  # See IO#gets
  def gets(*args)
    @in.gets(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :in flag when forking in order to use this" unless @in
    raise
  end

  # Read from the fork.
  # See IO#read
  def read(*args)
    @in.read(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :in flag when forking in order to use this" unless @in
    raise
  end

  # Read from the fork.
  # See IO#read_nonblock
  def read_nonblock(*args)
    @in.read_nonblock(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :in flag when forking in order to use this" unless @in
    raise
  end

  # Receive an object sent by the other process via send_object.
  # See ForkPool::Fork#send_object for an example.
  def receive_object
    Fork.read_marshalled(@in)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :in flag when forking in order to use this" unless @in
    raise
  end

  # Write to the fork.
  # See IO#puts
  def puts(*args)
    @out.puts(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :out flag when forking in order to use this" unless @out
    raise
  end

  # Write to the fork.
  # See IO#write
  def write(*args)
    @out.write(*args)
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :out flag when forking in order to use this" unless @out
    raise
  end

  # read instruction sent via @ctrl, used by :exception, :death_notice and
  # :return_value
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
  rescue EOFError # closed
    _wait(false) if _wait_upon_eof # update
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :ctrl flag when forking in order to use this" unless @ctrl
    raise
  end

  # Sends an object to the parent process
  #
  # Example:
  #   Demo = Struct.new(:a, :b, :c)
  #   pool.fork :name => :serializer do |parent|
  #     parent.send_object({:a => 'little', :nested => ['hash']})
  #     parent.send_object(Demo.new(1, :two, "three"))
  #   end
  #   p :received => pool[:serializer].receive_object # -> {:received=>{:a=>"little", :nested=>["hash"]}}
  #   p :received => pool[:serializer].receive_object # -> {:received=>#<struct Demo a=1, b=:two, c="three">}
  #
  # See ForkPool::Fork#receive_object
  def send_object(obj)
    Fork.write_marshalled(@out, obj)
    self
  rescue NoMethodError
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    raise FlagNotSpecified, "You must set the :out flag when forking in order to use this" unless @out
    raise
  end

  # Wait for this fork to terminate.
  # Returns self
  #
  # Example:
  #   start = Time.now
  #   fork = Fork.new do sleep 20 end
  #   fork.wait
  #   (Time.now-start).floor   # => 20
  def wait
    _wait unless @process_status
    self
  end

  # Sends the (SIG)HUP signal to this fork.
  # This is "gently asking the process to terminate".
  # This gives the process a chance to perform some cleanup.
  # See Fork#kill!, Fork#signal, Process::kill
  def kill
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill("HUP", @pid)
  end

  # Sends the (SIG)KILL signal to this fork.
  # The process will be immediatly terminated and will not have a chance to
  # do any cleanup.
  # See Fork#kill, Fork#signal, Process::kill
  def kill!
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill("KILL", @pid)
  end

  # Sends the given signal to this fork
  # See Fork#kill, Fork#kill!, Process::kill
  def signal(sig)
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    Process.kill(sig, @pid)
  end

  # Close all IOs
  def close # :nodoc:
    raise NotRunning, "Fork is not running yet, you must invoke #execute first." unless @pid
    @in.close if @in
    @out.close if @out
    @ctrl.close if @ctrl
  end

  def dup # :nodoc:
    raise TypeError, "can't dup ForkPool::Fork"
  end

  def clone # :nodoc:
    raise TypeError, "can't clone ForkPool::Fork"
  end

  def inspect # :nodoc:
    sprintf "#<%p pid=%p name=%p alive=%p>", self.class, @pid, @name, @alive
  end

private
  # Internal wait method that collects information when the process
  def _wait(blocking=true)
    _, status = *Process.wait2(@pid, blocking ? 0 : Process::WNOHANG)
    if status then
      @process_status = status
      @exit_status    = status.exitstatus
      read_remaining_ctrl
    end
  rescue Errno::ECHILD # can happen if the process is already collected
    raise "Can't determine exit status of #{self}, make sure to not interfere with process handling externally" unless @process_status
    self
  end

  # Embedds the forked code into everything needed to handle return value,
  # exceptions, cleanup etc.
  def child_process
    return_value = @block.call(self)
    Fork.write_marshalled(@ctrl, [:return_value, return_value]) if returns?
  rescue *IgnoreExceptions
    raise # reraise ignored exceptions as-is
  rescue Exception => e
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
