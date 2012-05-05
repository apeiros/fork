$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))

require 'forkpool'

start  = Time.now
pool   = ForkPool.new
future = pool.future do
  sleep 5
  {:hello => "world"}
end

sleep 1
puts "1 second passed"
sleep 1
puts "2 seconds passed"
sleep 1
puts "3 seconds passed"
sleep 1
puts "4 seconds passed"

start2 = Time.now
result = future.call
stop   = Time.now

printf "Result: %p\nTotal time: %.1fs\nFuture time: %.1fs\n", result, stop-start, stop-start2
