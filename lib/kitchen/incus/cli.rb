# frozen_string_literal: true

require "json"
require "open3"
require "mixlib/shellout"

module Kitchen
  module Incus
    # Raised when an `incus` CLI invocation fails.
    class CommandFailed < StandardError
      attr_reader :exit_code, :stderr

      def initialize(message, exit_code = nil, stderr = nil)
        @exit_code = exit_code
        @stderr = stderr
        super(message)
      end
    end

    # Thin wrapper around the `incus` command line client.
    #
    # Every command is executed with an argument vector (never through a
    # shell), so instance names, paths and commands are not subject to shell
    # interpolation on the workstation.
    class CLI
      Result = Struct.new(:stdout, :stderr, :exit_code) do
        def success?
          exit_code == 0
        end
      end

      # Default timeout for long running commands (converges, image pulls).
      DEFAULT_TIMEOUT = 60 * 60 * 3

      attr_reader :binary, :remote, :project

      # @param binary [String] path to the incus client
      # @param remote [String, nil] incus remote name; nil uses the default remote
      # @param project [String, nil] incus project; nil uses the remote's current project
      # @param logger [Kitchen::Logger, nil] logger used for debug + live output
      def initialize(binary: "incus", remote: nil, project: nil, logger: nil)
        @binary = binary || "incus"
        @remote = blank?(remote) ? nil : remote.to_s
        @project = blank?(project) ? nil : project.to_s
        @logger = logger
      end

      # @param name [String] instance name
      # @return [String] `remote:name` or `name`
      def target(name)
        remote ? "#{remote}:#{name}" : name.to_s
      end

      # `--project` flag (must follow the sub-command).
      def project_args
        project ? ["--project", project] : []
      end

      # Run an incus sub-command and capture its output.
      #
      # @param args [Array<String>] sub-command and arguments
      # @param input [String, nil] data written to stdin
      # @param live [Boolean] stream output to the logger while running
      # @param allow_failure [Boolean] return the result instead of raising
      # @return [Result]
      def run(*args, input: nil, live: false, allow_failure: false, timeout: DEFAULT_TIMEOUT)
        argv = [binary, *args.flatten.map(&:to_s)]
        debug("[incus] #{argv.join(" ")}")
        opts = { timeout:, environment: { "LC_ALL" => nil } }
        opts[:input] = input if input
        opts[:live_stream] = @logger if live && @logger
        sh = Mixlib::ShellOut.new(*argv, **opts)
        sh.run_command
        result = Result.new(sh.stdout, sh.stderr, sh.exitstatus)
        if !result.success? && !allow_failure
          raise CommandFailed.new(
            "`#{argv.join(" ")}` exited #{result.exit_code}: #{result.stderr.strip}",
            result.exit_code, result.stderr
          )
        end
        result
      rescue Errno::ENOENT
        raise CommandFailed, "incus client `#{binary}` not found on PATH"
      end

      # Execute a shell command inside an instance.
      #
      # @param name [String] instance name
      # @param command [String] POSIX shell command
      # @param user [Integer, nil] uid to run as
      # @param env [Hash] environment variables
      # @return [Result]
      def exec(name, command, user: nil, env: {}, **opts)
        run(*exec_args(name, user:, env:), "--", "sh", "-c", command, **opts)
      end

      # Arguments for `incus exec` up to (not including) the `--` separator.
      def exec_args(name, user: nil, env: {}, interactive: false)
        args = ["exec", *project_args]
        args << (interactive ? "-t" : "-T")
        args += ["--user", user.to_s] if user
        env.each { |k, v| args += ["--env", "#{k}=#{v}"] }
        args << target(name)
        args
      end

      # Copy a local file or directory into the instance under remote_dir.
      #
      # Uses a tar stream over `incus exec` so a whole directory tree is moved
      # in a single API round trip (much faster than `incus file push -r`
      # against remote servers). Falls back to `incus file push` when the
      # instance has no tar.
      def push(name, local, remote_dir, user: nil)
        local = File.expand_path(local)
        unless guest_has_tar?(name)
          return run("file", "push", *project_args, "-r", "-p", local, "#{target(name)}#{remote_dir.chomp("/")}/")
        end

        tar = ["tar", "-C", File.dirname(local), "-cf", "-", File.basename(local)]
        incus = [binary, *exec_args(name, user:), "--", "tar", "-C", remote_dir, "-xf", "-"]
        debug("[incus] #{tar.join(" ")} | #{incus.join(" ")}")

        statuses = nil
        err_r, err_w = IO.pipe
        # COPYFILE_DISABLE stops macOS bsdtar from adding ._ resource files.
        Open3.pipeline_w([{ "COPYFILE_DISABLE" => "1" }, *tar], incus, err: err_w) do |stdin, threads|
          stdin.close
          statuses = threads.map(&:value)
        end
        err_w.close
        stderr = err_r.read
        err_r.close
        return if statuses.all?(&:success?)

        raise CommandFailed.new("upload of #{local} to #{target(name)}:#{remote_dir} failed: #{stderr.strip}",
          statuses.map(&:exitstatus).find { |c| c != 0 }, stderr)
      end

      # Copy a file or directory out of the instance.
      def pull(name, remote_path, local)
        run("file", "pull", *project_args, "-r", "#{target(name)}#{remote_path}", local)
      end

      # @return [Hash, nil] the instance state document, or nil if absent
      def state(name)
        result = run("query", api_path("/1.0/instances/#{name}/state"), allow_failure: true, timeout: 60)
        return JSON.parse(result.stdout) if result.success?
        return nil if result.stderr =~ /not found/i

        raise CommandFailed.new("unable to query #{target(name)}: #{result.stderr.strip}", result.exit_code, result.stderr)
      end

      private

      def guest_has_tar?(name)
        @guest_has_tar ||= {}
        return @guest_has_tar[name] if @guest_has_tar.key?(name)

        @guest_has_tar[name] = exec(name, "command -v tar", allow_failure: true, timeout: 60).success?
      end

      # `incus query` refuses `--project`, so the project goes into the URL.
      def api_path(path)
        path = "#{path}?project=#{project}" if project
        remote ? "#{remote}:#{path}" : path
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def debug(msg)
        @logger&.debug(msg)
      end
    end
  end
end
