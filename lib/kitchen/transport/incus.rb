# frozen_string_literal: true

require "kitchen"
require "kitchen/transport/base"
require_relative "../incus/cli"
require_relative "../incus/version"

module Kitchen
  module Transport
    # Test Kitchen transport that talks to Incus instances through the
    # `incus` CLI (`incus exec`), so no SSH or network reachability to the
    # instance is required.
    class Incus < Kitchen::Transport::Base
      kitchen_transport_api_version 1

      plugin_version Kitchen::Incus::VERSION

      default_config :incus_binary, "incus"
      # uid to run commands as inside the instance (nil = root).
      default_config :user, nil
      # Extra environment variables for every command.
      default_config :env, {}
      # Command used for `kitchen login`.
      default_config :login_command, ["su", "-l"]
      # Seconds to wait for the instance agent to accept commands.
      default_config :ready_timeout, 300

      def finalize_config!(instance)
        super
        # Teach kitchen-inspec how to reach Incus instances, if it is in use.
        verifier = instance.verifier
        if defined?(Kitchen::Verifier::Inspec) && verifier.is_a?(Kitchen::Verifier::Inspec)
          require_relative "../incus/inspec_support"
          verifier.extend(Kitchen::Incus::InspecSupport)
        end
        self
      end

      def connection(state, &block)
        options = connection_options(config.to_hash.merge(state))
        Kitchen::Transport::Incus::Connection.new(options, &block)
      end

      # Builds the options shared by the transport connection and the InSpec
      # integration.
      #
      # @api private
      def connection_options(data)
        # These keys are written to the instance state by the incus driver.
        name = data[:incus_instance]
        raise ActionFailed, "No Incus instance recorded for #{instance.to_str}; run `kitchen create` first" if name.nil?

        {
          instance_name: name,
          remote: data[:incus_remote],
          project: data[:incus_project],
          incus_binary: data[:incus_binary],
          user: data[:user],
          env: data[:env] || {},
          login_command: Array(data[:login_command]),
          ready_timeout: data[:ready_timeout],
          logger:,
        }
      end

      # Connection that executes commands with `incus exec` and moves files
      # with tar streams.
      class Connection < Kitchen::Transport::Base::Connection
        def init_options(options)
          super
          @name = @options[:instance_name]
          @cli = Kitchen::Incus::CLI.new(
            binary: @options[:incus_binary],
            remote: @options[:remote],
            project: @options[:project],
            logger:
          )
        end

        # (see Base::Connection#execute)
        def execute(command)
          return if command.nil? || command.to_s.strip.empty?

          debug("[Incus] #{@cli.target(@name)} executing: #{command}")
          @cli.exec(@name, command, user: @options[:user], env: @options[:env], live: true)
        rescue Kitchen::Incus::CommandFailed => e
          raise TransportFailed.new(e.message, e.exit_code)
        end

        # (see Base::Connection#upload)
        def upload(locals, remote)
          @cli.exec(@name, "mkdir -p #{shell_quote(remote)}", user: @options[:user])
          Array(locals).each do |local|
            debug("[Incus] uploading #{local} to #{@cli.target(@name)}:#{remote}")
            @cli.push(@name, local, remote, user: @options[:user])
          end
        rescue Kitchen::Incus::CommandFailed => e
          raise TransportFailed.new(e.message, e.exit_code)
        end

        # (see Base::Connection#download)
        def download(remotes, local)
          FileUtils.mkdir_p(local)
          Array(remotes).each do |remote|
            @cli.pull(@name, remote, local)
          end
        rescue Kitchen::Incus::CommandFailed => e
          raise TransportFailed.new(e.message, e.exit_code)
        end

        # (see Base::Connection#login_command)
        def login_command
          args = @cli.exec_args(@name, user: @options[:user], env: @options[:env], interactive: true)
          LoginCommand.new(@cli.binary, [*args, "--", *@options[:login_command]])
        end

        # Waits until the Incus agent (VMs) or init (containers) accepts
        # commands.
        def wait_until_ready
          deadline = Time.now + (@options[:ready_timeout] || 300).to_i
          loop do
            result = @cli.exec(@name, "true", allow_failure: true, timeout: 30)
            return if result.success?
            raise TransportFailed, "#{@cli.target(@name)} not ready: #{result.stderr.strip}" if Time.now > deadline

            sleep 2
          end
        end

        private

        def shell_quote(str)
          "'#{str.to_s.gsub("'", "'\\\\''")}'"
        end
      end
    end
  end
end
