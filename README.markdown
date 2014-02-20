README
======


Summary
-------
Represents forks (child processes) as objects and makes interaction with forks easy.


Features
--------

* Object oriented usage of forks
* Easy-to-use implementation of future (`Fork.future { computation }.call # => result`)
* Provides facilities for IO between parent and fork
* Supports sending ruby objects to the forked process
* Supports reading ruby objects from the forked process


Installation
------------
`gem install fork`


Usage
-----

An example using a future:

```ruby
def fib(n) n < 2 ? n : fib(n-1)+fib(n-2); end # <-- bad implementation of fibonacci
future = Fork.future do
  fib(35)
end
# do something expensive in the parent process
puts future.call # this blocks, until the fork finished, and returns the last value
```


A more complex example, using some of Fork's features:
```ruby
# Create a fork with two-directional IO, which returns values and raises
# exceptions in the parent process.
fork = Fork.new :to_fork, :from_fork do |fork|
  while received = fork.receive_object
    p :fork_received => received
  end
end
fork.execute # spawn child process and start executing
fork.send_object(123)
puts "Fork runs as process with pid #{fork.pid}"
fork.send_object(nil) # terminate the fork
fork.wait # wait until the fork is indeed terminated
puts "Fork is dead, as expected" if fork.dead?
```


Links
-----

* [Online API Documentation](http://rdoc.info/github/apeiros/fork/)
* [Public Repository](https://github.com/apeiros/fork)
* [Bug Reporting](https://github.com/apeiros/fork/issues)
* [RubyGems Site](https://rubygems.org/gems/fork)


License
-------

You can use this code under the {file:LICENSE.txt BSD-2-Clause License}, free of charge.
If you need a different license, please ask the author.
