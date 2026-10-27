# frozen_string_literal: true

# Train transport plugin for Incus instances, used by InSpec / cinc-auditor.
#
# Commands run via `incus exec`, so the instance does not need SSH or a
# network path from the workstation. Can also be used standalone:
#
#   inspec exec profile -t incus://my-instance --remote myremote --project p
#
require "train"
require "train/plugins"
require_relative "kitchen/incus/cli"

module Train
  module Transports
    class Incus < Train.plugin(1)
      name "incus"

      option :host, required: true, desc: "Incus instance name"
      option :remote, default: nil, desc: "Incus remote (defaults to the client's default remote)"
      option :project, default: nil, desc: "Incus project"
      option :incus_binary, default: "incus", desc: "Path to the incus client"
      option :incus_user, default: nil, desc: "uid to run commands as"

      def connection(_instance_opts = nil)
        @connection ||= Connection.new(@options)
      end

      class Connection < BaseConnection
        def initialize(options)
          super(options)
          @name = @options[:host]
          @user = @options[:incus_user]
          @cli = Kitchen::Incus::CLI.new(
            binary: @options[:incus_binary],
            remote: @options[:remote],
            project: @options[:project]
          )
        end

        def uri
          "incus://#{@cli.target(@name)}"
        end

        def unique_identifier
          @cli.target(@name)
        end

        def local?
          false
        end

        private

        def run_command_via_connection(cmd, &_data_handler)
          result = @cli.exec(@name, cmd, user: @user, allow_failure: true)
          CommandResult.new(result.stdout, result.stderr, result.exit_code)
        end

        def file_via_connection(path, *_args)
          Train::File::Remote::Linux.new(self, path)
        end
      end
    end
  end
end
