require 'concurrent/array'
require 'concurrent/atomic/atomic_boolean'
require 'pty'
require 'json'

module Guard
    class Jest < Plugin

        class Server
            CR = 13.chr

            attr_reader :stdout, :stdin, :pid, :last_result, :options, :cmd, :pending

            def initialize(options = {})
                reload(options)
                @work_in_progress = Concurrent::AtomicBoolean.new(false)
                @pending = Concurrent::Array.new
            end

            def run(request)
                start unless alive?
                pending << request
                work_fifo_queue
                self
            end

            def failed?
                @pid && !alive?
            end

            def busy?
                @work_in_progress.true?
            end

            def wait_until_not_busy
                sleep(0.1) while busy?
            end

            def start
                @threads = []
                @work_in_progress.make_true
                @directory ? Dir.chdir(@directory) { spawn } : spawn
                @threads << Thread.new do
                    @stdout.each { |line| record_result(line) }
                end
                self
            end

            def alive?
                return false unless pid
                Process.kill(0, pid)
                return true
            rescue Errno::ESRCH # "No such process"
                return false
            rescue Errno::EPERM # "Operation not permitted, but it at least exists
                return true
            else
                return true
            end

            def stop
                stdin.write('q')
                sleep(0.1)
                return unless alive?
                Process.kill("TERM", pid)
                sleep(0.1)
                Process.kill("KILL", pid) if alive?
                @pid = nil
            end

            def reload(options)
                @options = options
                @directory = options[:directory]
                @cmd = options[:jest_cmd] + ' --json --silent true --watch'
                @cmd << " --config #{options[:config_file]}" if options[:config_file]
                if alive?
                    stop
                    start
                end
                self
            end

            private

            def work_fifo_queue
                return if busy? || pending.none?
                request = pending.first
                if request.all?
                    run_all
                else
                    run_paths(request.paths)
                end
            end

            def run_all
                @work_in_progress.make_true
                stdin.write('a')
            end

            def run_paths(paths)
                @work_in_progress.make_true
                stdin.write('p')
                # the sleep values simply "seem to work ok" and may need refinement
                sleep(0.1)
                stdin.write(paths.join('|'))
                sleep(0.1)
                stdin.write(CR)
            end

            def record_result(line)
                # looks vaguely jsonish if it starts with {"
                return unless line.start_with?('{"')
                begin
                    json = JSON.parse(line)
                    result = @pending.pop || RunRequest.new
                    result.satisfy(json)
                    @work_in_progress.make_false
                    work_fifo_queue
                rescue => e
                    Jest.logger.warn e
                end
            end

            def spawn
                Jest.logger.debug "starting jest with #{cmd}"
                @stdout, @stdin, @pid = PTY.spawn(cmd)
            end
        end
    end
end
