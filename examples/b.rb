$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))

require 'forkpool'

pool   = ForkPool.new
pool.fork :good, :exceptions do |parent|
end
pool.fork :raiser, :exceptions do |parent|
  raise "I haff an ekzeptschn!"
end
pool.fork :exiter, :exceptions do |parent|
  exit
end
pool.fork :exit3er, :exceptions do |parent|
  exit(3)
end

pool.wait_all

puts "All forks have terminated."

[:good, :raiser, :exiter, :exit3er].each do |name|
  puts "#{name}: status = #{pool[name].exit_status}, exception = #{pool[name].exception || 'none'}"
end

puts "Done"
