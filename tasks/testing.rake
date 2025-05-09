require_relative "#{__dir__}/../lib/opal/os"
require_relative "#{__dir__}/../lib/opal/cli_runners"

require 'timeout'
require 'rspec/core/rake_task'

OS = Opal::OS unless defined? OS

RSpec::Core::RakeTask.new(:rspec) do |t|
  t.pattern = 'spec/lib/**/*_spec.rb'
end

if ENV.key?('RUBYSPEC')
  warn "Did you mean RUBYSPECS=...? (RUBYSPEC was found among ENV variables)"
  exit 1
end

module Testing
  extend self

  def get_random_seed(env)
    random_seed = env['RANDOM_SEED'] ? env['RANDOM_SEED'] : rand(100_000)
    puts "export RANDOM_SEED=#{random_seed} # to re-use the same randomization"
    random_seed
  end

  module MSpec
    extend self

    def stubs
      %w[
        mspec/helpers/tmp
        mspec/helpers/environment
        mspec/guards/block_device
        a_file
        lib/spec_helper
        mspec/commands/mspec-run
        etc
        rubygems
        zlib
      ]
    end

    def specs(env = ENV)
      suite = env['SUITE']
      pattern = env['PATTERN']
      whitelist_pattern = !!env['RUBYSPECS']
      env['OPAL_PLATFORM_NAME'] = RbConfig::CONFIG['host_os'] unless env['OPAL_PLATFORM_NAME']

      excepting = []
      rubyspecs = File.read('spec/ruby_specs').lines.reject do |l|
        l.strip!
        l.start_with?('#') || l.empty? || (l.start_with?('!') && excepting.push(l.sub('!', 'spec/') + '.rb'))
      end.flat_map do |path|
        path = "spec/#{path}"
        File.directory?(path) ? Dir[path+'/*.rb'] : "#{path}.rb"
      end - excepting

      opalspecs = Dir['spec/{opal,lib/parser}/**/*_spec.rb']
      userspecs = Dir[pattern] if pattern
      userspecs &= rubyspecs if whitelist_pattern

      specs = []
      add_specs = ->(name, new_specs) do
        puts "Adding #{new_specs.size.to_s.rjust(3)} files (#{name})"
        specs += new_specs
      end

      if pattern
        add_specs["PATTERN=#{pattern}", userspecs.sort]
      elsif suite == 'opal'
        add_specs['spec/opal', opalspecs.sort]
      elsif suite == 'ruby'
        add_specs['spec/ruby', rubyspecs.sort]
      else
        warn 'Please provide at lease one of the following environment variables:'
        warn 'PATTERN # e.g. PATTERN=spec/ruby/core/numeric/**_spec.rb'
        warn 'SUITE   # can be either SUITE=opal or SUITE=ruby'
        exit 1
      end

      specs
    end

    def filters(suite, platform)
      opalspec_filters = Dir['spec/filters/**/*_opal.rb']

      if ENV['INVERT_RUNNING_MODE']
        # When we run an inverted test suite we should run only 'bugs'.
        # Unsupported features are not supported anyway
        rubyspec_filters = Dir['spec/filters/bugs/*.rb'] - opalspec_filters
      else
        rubyspec_filters = Dir["spec/filters/{unsupported,bugs,platform/#{platform}}/*.rb"] - opalspec_filters
      end

      suite == 'opal' ? opalspec_filters : rubyspec_filters
    end

    def write_file(filename, filters, specs, env)
      bm_filepath = env['BM_FILEPATH']

      [filters, specs].each do |files|
        files.map! { |s| "'#{s.sub(/^spec\//,'')}'" }
      end

      filter_requires = filters.map { |s| "require #{s}" }.join("\n")
      spec_requires = specs.map { |s| "requirable_spec_file #{s}" }.join("\n")
      spec_registration = specs.join(",\n  ")

      if bm_filepath
        enter_benchmarking_mode = "OpalBM.main.register(#{Integer(env['BM'])}, '#{bm_filepath}')"
      end

      random_seed = Testing.get_random_seed(env)

      env_data = env.map{ |k,v| "ENV[#{k.inspect}] = #{v.to_s.inspect}" unless v.nil? }.join("\n")

      File.write filename, <<~RUBY
        require 'opal/platform' # in node ENV is replaced
        #{env_data}

        require 'opal/full'
        require 'spec_helper'
        require 'securerandom'
        #{enter_benchmarking_mode}

        #{filter_requires}

        #{spec_requires}

        MSpec.register_files [
          #{spec_registration}
        ]

        srand(#{random_seed})
        MSpec.randomize = true

        # legacy MSpec
        def frozen_error_class
          FrozenError
        end

        MSpec.process
        OSpecFilter.main.unused_filters_message(list: #{!!ENV['LIST_UNUSED_FILTERS']})
        exit MSpec.exit_code
      RUBY
    end

    def bm_filepath
      mkdir_p 'tmp/bench'
      index = 0
      begin
        index += 1
        filepath = "tmp/bench/Spec#{index}"
      end while File.exist?(filepath)
      filepath
    end
  end

  module Minitest
    extend self
    extend FileUtils

    def write_file(filename, files = [], env = {})
      env_data = env.map{ |k,v| "ENV[#{k.inspect}] = #{v.to_s.inspect}" unless v.nil? }.join("\n")
      requires = files.map{|f| "require '#{f}'"}
      mkdir_p File.dirname(filename)

      random_seed = Testing.get_random_seed(env)

      File.write filename, <<-RUBY
        require 'opal/platform' # in node ENV is replaced
        require 'opal-parser'
        #{env_data}
        srand(#{random_seed})

        #{requires.join("\n")}
      RUBY
    end
  end

  class SauceLabs
    include FileUtils

    def initialize(options = {})
      @host = options.fetch(:host, '127.0.0.1')
      @port = options.fetch(:port, '3000')
      @username = options.fetch(:username)
      @access_key = options.fetch(:access_key)
      @tunnel = options.fetch(:tunnel, nil)
    end
    attr_reader :host, :port, :username, :access_key, :tunnel

    def with_server
      cd 'examples/rack'
      system 'bundle install' or raise 'bundle install failed'
      begin
        server = Process.spawn "bundle exec rackup --host #{host} --port #{port}"
        puts 'Waiting for server…'
        Timeout.timeout(30) do
          sleep 0.1 until system "curl -s 'http://#{host}:#{port}/' > /dev/null"
        end
        puts 'Server ready.'
        yield self
      rescue Timeout::Error
        puts 'Failed to start rack server'
        exit(1)
      ensure
        Process.kill(:TERM, server)
        Process.wait(server)
      end
    end

    def on_platform(options = {})
      browser = options.fetch(:browser)
      version = options.fetch(:version)
      platform = options.fetch(:platform, nil)
      device = options.fetch(:device, nil)

      puts "=============== Testing on browser: #{browser} v#{version} #{"(#{platform})" if platform}"
      require "selenium/webdriver"

      caps = {}
      caps[:platform]           = platform if platform
      caps[:browserName]        = browser if browser
      caps[:version]            = version if version
      caps[:device]             = device if device
      caps['tunnel-identifier'] = tunnel if tunnel

      driver = Selenium::WebDriver.for(
        :remote,
        url: "http://#{username}:#{access_key}@localhost:4445/wd/hub",
        desired_capabilities: caps
      )

      driver.get("http://#{host}:#{port}/")
      yield driver
      driver.quit
    end

    def test_title(driver)
      if (title = driver.title) == 'Bob is authenticated'
        puts "SUCCESS! title of webpage is: #{title}"
      else
        raise "FAILED! title of webpage is: #{title}"
      end
    end

    def run(**options)
      on_platform(**options) do |driver|
        test_title(driver)
      end
    end
  end

  class HTTPServer
    def with_server
      begin
        server = Process.spawn 'ruby test/opal/http_server.rb'
        puts 'Waiting for server…'
        Timeout.timeout(30) do
          sleep 0.1 until sinatra_server_running?
        end
        puts 'Server ready.'
        yield self
      rescue Timeout::Error
        puts 'Failed to start Sinatra server'
        exit(1)
      ensure
        if OS.windows?
          # https://blog.simplificator.com/2016/01/18/how-to-kill-processes-on-windows-using-ruby/
          # system("taskkill /f /pid #{pid}")
          Process.kill("KILL", server)
        else
          Process.kill(:TERM, server)
        end
        Process.wait(server)
      end
    end

    def sinatra_server_running?
      puts "Connecting to localhost:4567..."
      TCPSocket.new('localhost', '4567').close
      true
    rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
      false
    end
  end
end


pattern_usage = <<-DESC
Use PATTERN environment variable to manually set the glob for specs:

  # Will run all specs matching the specified pattern.
  # (Note: the ruby_specs filters will still apply)
  bundle exec rake mspec_nodejs PATTERN=spec/ruby/core/module/class_variable*_spec.rb
  bundle exec rake mspec_nodejs PATTERN=spec/ruby/core/numeric/**_spec.rb
DESC
runners = Opal::CliRunners.to_h.keys.map(&:to_s).reject { |r| r == 'compiler' }
platforms = (%w[opalopal_nodejs] + runners).sort
node_platforms = %w[nodejs opalopal_nodejs]
mspec_suites = %w[ruby opal]
minitest_suites = %w[cruby]

require 'opal/paths'
opalopal_cmdline = "-sreadline -rnodejs -rcorelib/string/unpack -popal/cli_runners/nodejs exe/opal -- #{Opal.paths.map{|i| "-I#{i}"}.join(" ")} --no-source-map "

platforms.each do |platform|
  mspec_suites.each do |suite|
    desc "Run the MSpec test suite on Opal::Builder/#{platform}" + pattern_usage
    task :"mspec_#{suite}_#{platform}" do
      filename = "tmp/mspec_#{platform}.rb"
      if platform.start_with? "opalopal_"
        platform = platform.split('_').last
        cmdline = opalopal_cmdline
      end
      mkdir_p File.dirname(filename)
      bm_filepath = Testing::MSpec.bm_filepath if ENV['BM']
      specs_env = {
        'SUITE' => suite,
        'FORMATTER' => platform, # Use the current platform as the default formatter
        'BM_FILEPATH' => bm_filepath,
      }.merge(ENV.to_hash)
      Testing::MSpec.write_file filename, Testing::MSpec.filters(suite, platform), Testing::MSpec.specs(specs_env), specs_env

      stubs = Testing::MSpec.stubs.map{|s| "-s#{s}"}.join(' ')

      sh "ruby -w -rbundler/setup -r#{__dir__}/testing/mspec_special_calls "\
         "exe/opal #{cmdline} -Ispec/mspec/lib -Ispec -Ilib #{stubs} -R#{platform} -Dwarning -A --enable-source-location #{filename}"

      if bm_filepath
        puts "Benchmark results have been written to #{bm_filepath}"
        puts "To view the results, run bundle exec rake bench:report"
      end
    end
  end

  minitest_suites.each do |suite|
    desc "Run the Minitest suite on Opal::Builder/#{platform}" + pattern_usage
    task :"minitest_#{suite}_#{platform}" do
      if ENV.key? 'FILES'
        files = Dir[ENV['FILES']]
        includes = "-Itmp"
      else
        includes = "-Itest/cruby/test"
        files = %w[
          benchmark/test_benchmark.rb
          opal/test_io_buffer.rb
          opal/test_keyword.rb
          opal/test_base64.rb
          opal/test_openuri.rb
          opal/test_uri.rb
          opal/unsupported_and_bugs.rb
          opal/test_matrix.rb
          opal/promisev2/test_always.rb
          opal/promisev2/test_error.rb
          opal/promisev2/test_rescue.rb
          opal/promisev2/test_then.rb
          opal/promisev2/test_trace.rb
          opal/promisev2/test_value.rb
          opal/promisev2/test_when.rb
        ]
      end
      Testing::HTTPServer.new.with_server do |session|
        filename = "tmp/minitest_#{suite}_#{platform}.rb"
        if platform.start_with? "opalopal_"
          platform = platform.split('_').last
          cmdline = opalopal_cmdline
        end
        files.push('nodejs') if platform == 'nodejs'
        Testing::Minitest.write_file(filename, files, ENV)

        stubs = "-soptparse -sio/console -stimeout -smutex_m -srubygems -stempfile -smonitor"
        includes = "-Itest -Ilib -Ivendored-minitest #{includes}"

        sh "ruby -rbundler/setup "\
         "exe/opal #{cmdline} #{includes} #{stubs} -R#{platform} -Dwarning -A --enable-source-location #{filename}"
      end
    end
  end
end

node_platforms.each do |platform|
  # The name ends with the platform, which is of course mandated in this case
  desc "Run the Node.js Minitest suite on #{platform}"
  task :"minitest_node_#{platform}" do
    if platform.start_with? "opalopal_"
      platform = platform.split('_').last
      cmdline = opalopal_cmdline
    end
    files = %w[
      nodejs
      opal-parser
      nodejs/test_dir.rb
      nodejs/test_env.rb
      nodejs/test_error.rb
      nodejs/test_file.rb
      nodejs/test_file_encoding.rb
      nodejs/test_io.rb
      nodejs/test_opal_builder.rb
      nodejs/test_string.rb
      nodejs/test_await.rb
      nodejs/test_yaml.rb
    ]

    filename = "tmp/minitest_node_nodejs.rb"
    Testing::Minitest.write_file(filename, files, ENV)

    stubs = "-soptparse -sio/console -stimeout -smutex_m -srubygems -stempfile -smonitor"
    includes = "-Itest -Ilib -Ivendored-minitest"

    use_strict_opt = ENV['USE_STRICT'] ? ' --use-strict' : ''
    sh "ruby -rbundler/setup "\
      "exe/opal #{cmdline} #{includes} #{stubs} -R#{platform} -Dwarning -A --enable-source-location#{use_strict_opt} #{filename}"
  end
end

desc 'Run smoke tests with opal-rspec to see if something is broken'
task :smoke_test do
  opal_rspec_dir = File.expand_path('tmp/smoke_test_opal_rspec')
  gemfile_name = 'opal_rspec_smoketest.Gemfile'
  actual_output_path = "#{opal_rspec_dir}/output.txt"

  # Travis caching might be creating this, manage the state idempotently
  unless File.exist?(File.join(opal_rspec_dir, '.git'))
    rm_rf opal_rspec_dir
    sh "git clone https://github.com/opal/opal-rspec.git #{opal_rspec_dir}"
  end

  cp "tasks/testing/#{gemfile_name}", "#{opal_rspec_dir}/Gemfile"

  cd opal_rspec_dir do
    Bundler.with_unbundled_env do
      sh 'bundle check && bundle update opal-rspec || bundle install'
      sh %{bundle exec opal-rspec --color --default-path=../../spec ../../spec/lib/deprecations_spec.rb > #{actual_output_path}}

      actual_output = File.read(actual_output_path)
      begin
        require 'rspec/expectations'
        extend RSpec::Matchers
        expect(actual_output.lines[0]).to    eq("\n")
        expect(actual_output.lines[1]).to    eq("Opal::Deprecations\n")
        expect(actual_output.lines[2]).to    eq("\e[32m  defaults to warn\e[0m\n")
        expect(actual_output.lines[3]).to    eq("\e[32m  can be set to raise\e[0m\n")
        expect(actual_output.lines[4]).to    eq("\n")

        expect(actual_output.lines[5]).to match(%r{Top 2 slowest examples \(\d+\.\d+ seconds, \d+\.\d+% of total time\):\n})
        expect(actual_output.lines[7]).to match(%r{    \[1m\d+\.\d+\[0m \[1mseconds\[0m .*deprecations_spec\.rb:7\n})
        expect(actual_output.lines[9]).to match(%r{    \[1m\d+\.\d+\[0m \[1mseconds\[0m .*deprecations_spec\.rb:12\n})
        expect(actual_output.lines[10]).to    eq("\n")
        expect(actual_output.lines[11]).to match(%r{^Finished in \d+\.\d+ seconds \(files took \d+\.\d+ seconds to load\)\n$})
        expect(actual_output.lines[12]).to    eq("[32m2 examples, 0 failures[0m\n")
        expect([
          actual_output.lines[6],
          actual_output.lines[8],
        ]).to contain_exactly(
          "  Opal::Deprecations defaults to warn\n",
          "  Opal::Deprecations can be set to raise\n",
        )
      rescue RSpec::Expectations::ExpectationNotMetError
        warn $!.message
        warn "\n\n== Full output:\n#{actual_output}"
        exit 1
      end
    end
  end

  puts "Smoke test was successful!"
end

desc 'Run browser tests with SauceLabs'
task :browser_test do
  credentials = {
    username: ENV['SAUCE_USERNAME'] || warn('missing SAUCE_USERNAME env var'),
    access_key: ENV['SAUCE_ACCESS_KEY'] || warn('missing SAUCE_ACCESS_KEY env var'),
    tunnel: ENV['TRAVIS_JOB_NUMBER'],
  }

  # Exit if we're missing credentials.
  exit unless credentials[:username] && credentials[:access_key]

  Testing::SauceLabs.new(credentials).with_server do |session|
    session.run(browser: 'Internet Explorer', version: '9')
    session.run(browser: 'Internet Explorer', version: '10')
    session.run(browser: 'Internet Explorer', version: '11')
    # session.run(browser: 'Edge', version: '13') # something goes wrong
    session.run(browser: 'Firefox', version: '47')
    session.run(browser: 'Firefox', version: '48')
    # session.run(browser: 'Chrome', version: '52') # chrome webdriver is broken
    # session.run(browser: 'Chrome', version: '53') # chrome webdriver is broken
    session.run(browser: 'Safari', version: '8')
    session.run(browser: 'Safari', version: '9')
    session.run(browser: 'Safari', version: '10')
  end
end

platforms.each do |platform|
  desc "Run the whole MSpec suite on #{platform}"
  task :"mspec_#{platform}" => mspec_suites.map { |suite| :"mspec_#{suite}_#{platform}" }
end

platforms.each do |platform|
  desc "Run the whole Minitest suite on #{platform}"
  task :"minitest_#{platform}" => minitest_suites.map { |suite| :"minitest_#{suite}_#{platform}" }
end

desc "Run the whole MSpec suite on all platforms"
task :mspec    => [:mspec_chrome, :mspec_nodejs]

desc "Run the whole Minitest suite on all platforms"
task :minitest => [:minitest_chrome, :minitest_nodejs, :minitest_node_nodejs]

desc "Run all tests"
task :test_all => [:rspec, :mspec, :minitest]

# deprecated, can be removed after 0.11
task(:cruby_tests) { warn "The task 'cruby_tests' has been renamed to 'minitest_cruby_nodejs'."; exit 1 }
task(:test_cruby)  { warn "The task 'test_cruby' has been renamed to 'minitest_cruby_nodejs'."; exit 1 }
task(:test_nodejs) { warn "The task 'test_nodejs' has been renamed to 'minitest_node_nodejs'."; exit 1 }
