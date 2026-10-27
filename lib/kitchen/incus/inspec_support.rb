# frozen_string_literal: true

require "train-incus"

module Kitchen
  module Incus
    # Mixed into a Kitchen::Verifier::Inspec instance by the incus transport
    # so InSpec runs through the `incus` train backend (see train-incus.rb).
    # kitchen-inspec dispatches on `runner_options_for_<transport name>`.
    module InspecSupport
      private

      def runner_options_for_incus(config_data)
        opts = instance.transport.connection_options(config_data)
        {
          "backend" => "incus",
          "logger" => logger,
          "host" => opts[:instance_name],
          "remote" => opts[:remote],
          "project" => opts[:project],
          "incus_binary" => opts[:incus_binary],
          "incus_user" => opts[:user],
        }.compact
      end
    end
  end
end
