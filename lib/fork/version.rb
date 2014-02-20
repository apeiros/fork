# encoding: utf-8

begin
  require 'rubygems/version' # newer rubygems use this
rescue LoadError
  require 'gem/version' # older rubygems use this
end



class Fork

  # The currently required version of the Fork gem
  Version = Gem::Version.new("1.0.1")
end
