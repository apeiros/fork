require 'fork'

class ForkTest < Test::Unit::TestCase
  test "Examples from readme" do
    fork = Fork.new :to_fork, :from_fork do |fork|
      while received = fork.receive_object
        p :fork_received => received
      end
    end

    output  = capture_stdout do
      fork.execute # spawn child process and start executing
      fork.send_object(123)
      puts "Fork runs as process with pid #{fork.pid}"
      fork.send_object(nil) # terminate the fork
      fork.wait # wait until the fork is indeed terminated
      puts "Fork is dead, as expected" if fork.dead?
    end

    assert_match(/Fork runs as process with pid \d+\nFork is dead, as expected\n/, output)
    assert fork.success?
  end

  test "Examples from Fork class docs" do
    def fib(n) n < 2 ? n : fib(n-1)+fib(n-2); end # <-- bad implementation of fibonacci
    fork = Fork.new :return do
      fib(20)
    end
    fork.execute
    assert fork.pid
    assert fork.alive?
    assert fork.return_value

    fork = Fork.execute :return do
      fib(20)
    end
    assert fork.return_value

    future = Fork.future do
      fib(20)
    end
    assert future.call
  end

  test "Examples from Fork.future docs" do
    assert_equal 1, Fork.future { 1 }.call

    assert_nothing_raised do
      result = Fork.future { sleep 0.5; 1 } # assume a complex computation instead of sleep(2)
      sleep 0.5                             # assume another complex computation
      start  = Time.now
      assert_equal 1, result.call                         # => 1
      elapsed_time = Time.now-start       # => <1s as the work was done parallely
    end
  end

  test "Examples from Fork.return docs" do
    assert_equal 1, Fork.return { 1 }
  end

  test "Examples from Fork#send_object docs" do
    Demo = Struct.new(:a, :b, :c)
    fork = Fork.new :from_fork do |parent|
      parent.send_object({:a => 'little', :nested => ['hash']})
      parent.send_object(Demo.new(1, :two, "three"))
    end
    fork.execute
    assert_equal({:a=>"little", :nested=>["hash"]}, fork.receive_object)
    assert_equal(Demo.new(1, :two, "three"), fork.receive_object)
  end

  test "Fork.future { value }.call returns value" do
    value = 15
    assert_equal value, Fork.future { value }.call
  end

  test "Fork.future { value }.call returns value, even when the process is already gone" do
    value   = 15
    future  = Fork.future { value }
    sleep(0.5)
    result  = future.call
    assert_equal value, result
  end
end
