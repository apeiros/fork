# encoding: utf-8

Gem::Specification.new do |s|
  s.name                      = "fork"
  s.version                   = "1.0.1"
  s.authors                   = "Stefan Rusterholz"
  s.email                     = "stefan.rusterholz@gmail.com"
  s.homepage                  = "https://github.com/apeiros/fork"

  s.summary                   = <<-SUMMARY.gsub(/^    /, '').chomp
    Represents forks (child processes) as objects and makes interaction with forks easy.
  SUMMARY
  s.description               = <<-DESCRIPTION.gsub(/^    /, '').chomp
    Represents forks (child processes) as objects and makes interaction with forks easy.
    It provides a simple interface to create forked futures, get the return value of the
    fork, get an exception raised in the fork, and to send objects between parent and
    forked process.
  DESCRIPTION

  s.files                     =
    Dir['bin/**/*'] +
    Dir['examples/**/*'] +
    Dir['lib/**/*'] +
    Dir['rake/**/*'] +
    Dir['test/**/*'] +
    Dir['*.gemspec'] +
    %w[
      LICENSE.txt
      Rakefile
      README.markdown
    ]

  if File.directory?('bin') then
    executables = Dir.chdir('bin') { Dir.glob('**/*').select { |f| File.executable?(f) } }
    s.executables = executables unless executables.empty?
  end

  s.required_rubygems_version = Gem::Requirement.new("> 1.3.1")
  s.rubygems_version          = "1.3.1"
  s.specification_version     = 3
end
