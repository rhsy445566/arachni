=begin
    Copyright 2010-2013 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

module Arachni

#
# The namespace under which all plugins exist.
#
module Plugins
end

module Plugin

class Error < Arachni::Error
    class UnsatisfiedDependency < Error
    end
end

#
# Holds and manages the plugins.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Manager < Arachni::Component::Manager
    include Utilities
    extend  Utilities

    # Namespace under which all plugins reside.
    NAMESPACE = Arachni::Plugins

    # Expressions matching default plugins.
    DEFAULT   = %w(defaults/*)

    # @param    [Arachni::Framework]    framework   Framework instance.
    def initialize( framework )
        super( framework.opts.dir['plugins'], NAMESPACE )
        @framework = framework

        @jobs = []
    end

    # Loads the default plugins.
    #
    # @see DEFAULT
    def load_default
        load DEFAULT
    end
    alias :load_defaults :load_default

    # @return   [Array<String>] Components to load, by name.
    def default
        parse DEFAULT
    end
    alias :defaults :default

    # Runs each plug-in in its own thread.
    #
    # @raise [Error::UnsatisfiedDependency]
    #   If the environment is {#sane_env? not sane}.
    def run
        ordered   = []
        unordered = []

        loaded.each do |name|
            ph = { name => self[name] }
            if order = self[name].info[:priority]
                ordered[order] ||= []
                ordered[order] << ph
            else
                unordered << ph
            end
        end
        ordered << unordered
        ordered.flatten!

        ordered.each do |ph|
            name   = ph.keys.first
            plugin = ph.values.first

            if( ret = sane_env?( plugin ) ) != true
                deps = ''
                if !ret[:gem_errors].empty?
                    print_bad "[#{name}] The following plug-in dependencies aren't satisfied:"
                    ret[:gem_errors].each { |gem| print_bad "\t* #{gem}" }

                    deps = ret[:gem_errors].join( ' ' )
                    print_bad 'Try installing them by running:'
                    print_bad "\tgem install #{deps}"
                end

                fail Error::UnsatisfiedDependency,
                     "Plug-in dependencies not met: #{name} -- #{deps}"
            end

            opts = @framework.opts.plugins[name]
            opts = prep_opts( name, self[name], opts )

            @jobs << Thread.new {

                exception_jail( false ) {
                    Thread.current[:name]     = name
                    Thread.current[:instance] = plugin_new = create( name, opts )

                    plugin_new.prepare
                    plugin_new.run
                    plugin_new.clean_up
                }

            }
        end

        return if @jobs.empty?

        print_status 'Waiting for plugins to settle...'
        ::IO::select( nil, nil, nil, 1 )
    end

    # Checks whether or not the environment satisfies all plugin dependencies.
    #
    # @return   [TrueClass, Hash]
    #   `true` if the environment is sane, a hash with errors otherwise.
    def sane_env?( plugin )
        gem_errors = []

        plugin.gems.each do |gem|
            begin
                require gem
            rescue LoadError
                gem_errors << gem
            end
        end

        return { gem_errors: gem_errors } if !gem_errors.empty?
        true
    end

    def create( name, opts ={} )
        self[name].new( @framework, opts )
    end

    # Blocks until all plug-ins have finished executing.
    def block
        while !@jobs.empty?
            print_debug
            print_debug "Waiting on the following (#{@jobs.size}) plugins to finish:"
            print_debug job_names.join( ', ' )
            print_debug

            @jobs.delete_if { |j| !j.alive? }
            ::IO::select( nil, nil, nil, 1 )
        end
        nil
    end

    # @return   [Bool]
    #   `false` if all plug-ins have finished executing, `true` otherwise.
    def busy?
        !@jobs.reject{ |j| j.alive? }.empty?
    end

    # @return   [Array] Names of all running plug-ins.
    def job_names
        @jobs.map{ |j| j[:name] }
    end

    # @return   [Array<Thread>] All the running threads.
    def jobs
        @jobs
    end

    #
    # Kills a plug-in by `name`.
    #
    # @param    [String]    name
    #
    def kill( name )
        job = get( name )
        return true if job && job.kill
        false
    end

    #
    # Gets a running plug-in by name.
    #
    # @param    [String]    name
    #
    # @return   [Thread]
    #
    def get( name )
        @jobs.each { |job| return job if job[:name] == name }
        nil
    end

    #
    # Registers plugin results.
    #
    # @param    [Arachni::Plugin::Base]    plugin   Instance of a plugin.
    # @param    [Object]    results
    #
    def register_results( plugin, results )
        mutex.synchronize {
            name = nil
            self.each do |k, v|
                if plugin.class.name == v.name
                    name = k
                    break
                end
            end

            return if !name
            self.class.results[name] =
                { results: results }.merge( plugin.class.info )
        }
    end

    def self.mutex
        @mutex ||= Mutex.new
    end
    def mutex
        self.class.mutex
    end

    def self.results
        @results ||= {}
    end
    def results
        self.class.results
    end

    def self.results=( v )
        @results = v
    end
    def results=( v )
        self.class.results = v
    end

    def self.reset
        results.clear
        remove_constants( NAMESPACE )
    end
    def reset
        self.class.reset
    end

end
end
end
