$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))

require 'fork/queue'

start = Time.now
queue = Fork::Queue.new(4)

20.times do |i|
  queue.enqueue do
    sleep 0.1*(4-(i%4)) # sequence: 0.4, 0.3, 0.2, 0.1, 0.4, 0.3, 0.2, 0.1, ...
    i
  end
end

20.times do
  p queue.next
end

duration = (Time.now-start)*1000

puts "Done. Took #{duration}ms"
