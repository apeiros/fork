require 'stringio'

class Test::Unit::TestCase
  def self.test(desc, &impl)
    define_method("test #{desc}", &impl)
  end

  def capture_stdout
    captured  = StringIO.new
    $stdout   = captured
    yield
    captured.string
  ensure
    $stdout = STDOUT
  end
end
