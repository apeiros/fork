$LOAD_PATH.unshift(File.expand_path('../../lib', __FILE__))

require 'forkpool'

pool   = ForkPool.new
fork_a = pool.fork :a do |parent|
  parent.puts("started #{ForkPool.name}")
  puts "Got from parent: ", parent.gets
  parent.puts "got it"
end
fork_b = pool.fork :b do |parent|
  parent.puts("started #{ForkPool.name}")
  puts "Got from parent: ", parent.gets
  exit 1
end

puts "Got from fork a: ", fork_a.gets
fork_a.puts "Daddy says hi to A"
fork_a.gets

puts "Got from fork b: ", fork_b.gets
fork_b.puts "Daddy says hi to B"

pool.wait_all
puts "Fork a, exit status: #{fork_a.exit_status.inspect}"
puts "Fork b, exit status: #{fork_b.exit_status.inspect}"

pool.forget_all!

Demo = Struct.new(:a, :b, :c)
pool.fork :serializer do |parent|
  parent.send_object({:a => 'little', :nested => ['hash']})
  parent.send_object(Demo.new(1, :two, "three"))
end
p :received => pool[:serializer].receive_object
p :received => pool[:serializer].receive_object

puts "Done"
