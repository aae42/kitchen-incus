# frozen_string_literal: true

require "securerandom"
require "time"
require "kitchen"
require "kitchen/driver/base"
require_relative "../incus/cli"
require_relative "../incus/version"

module Kitchen
  module Driver
    # Test Kitchen driver for Incus containers and virtual machines.
    #
    # Instances are managed with the `incus` CLI, so any remote configured in
    # the client (local unix socket or a remote HTTPS server/cluster) works.
    class Incus < Kitchen::Driver::Base
      kitchen_driver_api_version 2

      plugin_version Kitchen::Incus::VERSION

      # Incus remote to use; nil uses the client's default remote.
      default_config :remote, nil
      # Incus project; nil uses the remote's current project.
      default_config :project, nil
      # Image to launch. Defaults to images:<distro>/<version> derived from
      # the platform name (e.g. ubuntu-24.04 -> images:ubuntu/24.04).
      default_config :image do |driver|
        driver.default_image
      end
      # Launch a virtual machine instead of a container.
      default_config :vm, false
      # Profiles to apply (empty = server default profile).
      default_config :profiles, []
      # Instance config keys (e.g. limits.cpu: 2, security.nesting: true).
      default_config :config, {}
      # Extra devices: { name => { type: disk, source: /x, path: /y } }.
      default_config :devices, {}
      default_config :storage_pool, nil
      default_config :network, nil
      # Instance type shorthand (e.g. c2-m4) passed to `incus init --type`.
      default_config :instance_type, nil
      # Explicit instance name; default is kitchen-<instance>-<random>.
      default_config :instance_name, nil
      # Seconds to wait for the instance to accept commands (and get an IP).
      default_config :ready_timeout, 300
      # Wait for a global IP address before continuing (needed to download Cinc).
      default_config :wait_for_network, true
      # Shell commands run inside the instance after it boots.
      default_config :provision_commands, []
      # Install curl/ca-certificates/sudo when missing, so Cinc can be
      # downloaded and the provisioner's default `sudo -E` works.
      default_config :install_prerequisites, true
      default_config :incus_binary, "incus"

      # Shell script that installs the packages the Cinc installer and Test
      # Kitchen expect, using whichever package manager is present.
      PREREQS_SCRIPT = <<~'SH'
        missing=""
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || missing="$missing curl"
        command -v sudo >/dev/null 2>&1 || missing="$missing sudo"
        command -v tar >/dev/null 2>&1 || missing="$missing tar"
        [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || missing="$missing ca-certificates"
        [ -z "$missing" ] && exit 0
        echo "Installing missing prerequisites:$missing"
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -q && apt-get install -y -q $missing
        elif command -v dnf >/dev/null 2>&1; then dnf install -y $missing
        elif command -v yum >/dev/null 2>&1; then yum install -y $missing
        elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install $missing
        elif command -v apk >/dev/null 2>&1; then apk add --no-cache $missing
        elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm $missing
        else echo "No supported package manager found; please install:$missing" >&2; exit 1
        fi
      SH

      def finalize_config!(instance)
        super
        warn_if_chef_provisioner(instance)
        self
      end

      # (see Base#create)
      def create(state)
        super

        if state[:incus_instance] && cli(state).state(state[:incus_instance])
          info("Incus instance #{cli(state).target(state[:incus_instance])} already exists")
          cli(state).run("start", *cli(state).project_args, cli(state).target(state[:incus_instance]), allow_failure: true)
        else
          state[:incus_instance] = config[:instance_name] || generate_name
          # Record the resolved remote/project so later actions hit the same
          # server even if the client's default remote changes.
          state[:incus_remote] = config[:remote] || resolve_default_remote
          state[:incus_project] = config[:project]
          launch(state)
        end

        wait_until_ready(state)
        state[:hostname] = ip_address(cli(state).state(state[:incus_instance]))
        bootstrap(state)
        info("Incus instance #{cli(state).target(state[:incus_instance])} ready#{state[:hostname] ? " (#{state[:hostname]})" : ""}")
      rescue Kitchen::Incus::CommandFailed => e
        raise ActionFailed, e.message
      end

      # (see Base#destroy)
      def destroy(state)
        name = state[:incus_instance]
        return if name.nil?

        c = cli(state)
        info("Destroying Incus instance #{c.target(name)}")
        result = c.run("delete", *c.project_args, "--force", c.target(name), allow_failure: true)
        if !result.success? && result.stderr !~ /not found/i
          raise ActionFailed, "Failed to delete #{c.target(name)}: #{result.stderr.strip}"
        end

        %i{incus_instance incus_remote incus_project hostname}.each { |k| state.delete(k) }
      end

      # (see Base#status)
      def status(state)
        name = state[:incus_instance]
        now = Time.now.utc.iso8601
        return { live: false, state: "not created", source: "incus", checked_at: now } if name.nil?

        doc = cli(state).state(name)
        if doc.nil?
          return { live: false, state: "missing", source: "incus", resource_id: name,
                   message: "Instance not found on Incus server", checked_at: now }
        end

        status = doc["status"].to_s
        { live: status == "Running", state: status.downcase, source: "incus",
          resource_id: cli(state).target(name), checked_at: now }
      end

      # (see Base#doctor)
      def doctor(_state)
        result = cli({}).run("version", allow_failure: true, timeout: 30)
        if result.stdout =~ /Server version: unreachable/ || !result.success?
          error("Unable to reach Incus server: #{(result.stdout + result.stderr).strip}")
          return true
        end
        false
      rescue Kitchen::Incus::CommandFailed => e
        error(e.message)
        true
      end

      # Derive an images: remote alias from the platform name.
      #
      # @return [String]
      def default_image
        name = instance.platform.name
        if (m = name.match(/\A(.+?)-(\d[\w.]*)\z/))
          "images:#{m[1]}/#{m[2]}"
        else
          "images:#{name}"
        end
      end

      private

      def cli(state)
        Kitchen::Incus::CLI.new(
          binary: config[:incus_binary],
          remote: state.fetch(:incus_remote, config[:remote]),
          project: state.fetch(:incus_project, config[:project]),
          logger:
        )
      end

      def resolve_default_remote
        remote = cli({}).run("remote", "get-default", timeout: 30).stdout.strip
        remote.empty? ? nil : remote
      end

      def launch(state)
        c = cli(state)
        target = c.target(state[:incus_instance])
        info("Creating Incus #{config[:vm] ? "VM" : "container"} #{target} from #{config[:image]}")

        args = ["init", *c.project_args, config[:image], target, "--quiet"]
        args << "--vm" if config[:vm]
        Array(config[:profiles]).each { |p| args.push("--profile", p) }
        config[:config].each { |k, v| args.push("--config", "#{k}=#{v}") }
        args.push("--storage", config[:storage_pool]) if config[:storage_pool]
        args.push("--network", config[:network]) if config[:network]
        args.push("--type", config[:instance_type]) if config[:instance_type]
        c.run(*args)

        config[:devices].each do |dev, props|
          props = props.transform_keys(&:to_s)
          type = props.delete("type") || raise(ActionFailed, "device #{dev} is missing a type")
          c.run("config", "device", "add", *c.project_args, target, dev.to_s, type,
            *props.map { |k, v| "#{k}=#{v}" })
        end

        c.run("start", *c.project_args, target)
      end

      def wait_until_ready(state)
        c = cli(state)
        name = state[:incus_instance]
        deadline = Time.now + config[:ready_timeout].to_i
        info("Waiting for #{c.target(name)} to accept commands#{config[:wait_for_network] ? " and get an IP" : ""}")

        loop do
          ready = c.exec(name, "true", allow_failure: true, timeout: 30).success?
          ready &&= !ip_address(c.state(name)).nil? if config[:wait_for_network]
          return if ready
          raise ActionFailed, "Timed out after #{config[:ready_timeout]}s waiting for #{c.target(name)}" if Time.now > deadline

          sleep 2
        end
      end

      # First global address on a non-loopback interface, IPv4 preferred.
      def ip_address(doc)
        addrs = (doc&.dig("network") || {}).reject { |_, n| n["type"] == "loopback" }
          .values.flat_map { |n| n["addresses"] || [] }
          .select { |a| a["scope"] == "global" }
        (addrs.find { |a| a["family"] == "inet" } || addrs.first)&.dig("address")
      end

      def bootstrap(state)
        c = cli(state)
        name = state[:incus_instance]
        commands = []
        commands << PREREQS_SCRIPT if config[:install_prerequisites]
        commands.concat(Array(config[:provision_commands]))
        commands.each { |cmd| c.exec(name, cmd, live: true) }
      end

      def generate_name
        base = instance.name.downcase.gsub(/[^a-z0-9-]/, "-").squeeze("-")
        # Incus names: <= 63 chars, letters/digits/hyphens, must not start with a digit.
        "kitchen-#{base}"[0, 55].sub(/-+\z/, "") + "-#{SecureRandom.hex(3)}"
      end

      def warn_if_chef_provisioner(instance)
        prov = instance.provisioner
        return unless prov.class.name.to_s =~ /\AKitchen::Provisioner::Chef/
        return if defined?(Kitchen::Provisioner::CincBase) && prov.is_a?(Kitchen::Provisioner::CincBase)

        warn("Provisioner #{prov.name} will install Chef Infra Client; use `cinc_infra` (kitchen-cinc) to install Cinc instead")
      end
    end
  end
end
