b, a = IO.pipe
a.puts "hello"
puts b.gets

b.puts "yes?"
puts a.gets

puts "done"
