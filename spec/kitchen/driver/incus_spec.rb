# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kitchen::Driver::Incus do
  let(:platform_name) { "ubuntu-24.04" }
  let(:config) { {} }
  let(:instance) do
    double("instance", name: "default-ubuntu-2404", to_str: "<default-ubuntu-2404>",
      logger: Kitchen::Logger.new(stdout: StringIO.new),
      platform: double("platform", name: platform_name),
      provisioner: double("provisioner", name: "CincInfra"))
  end
  let(:driver) { described_class.new(config).finalize_config!(instance) }
  let(:ok) { Kitchen::Incus::CLI::Result.new("", "", 0) }

  describe "default image" do
    it { expect(driver[:image]).to eq("images:ubuntu/24.04") }

    context "with a multi-part distro" do
      let(:platform_name) { "centos-stream-9" }
      it { expect(driver[:image]).to eq("images:centos-stream/9") }
    end

    context "without a version" do
      let(:platform_name) { "archlinux" }
      it { expect(driver[:image]).to eq("images:archlinux") }
    end
  end

  it "generates valid incus instance names" do
    name = driver.send(:generate_name)
    expect(name).to match(/\Akitchen-default-ubuntu-2404-[0-9a-f]{6}\z/)
    expect(name.length).to be <= 63
  end

  it "truncates long instance names to 63 characters" do
    allow(instance).to receive(:name).and_return("a" * 100)
    expect(driver.send(:generate_name).length).to be <= 63
  end

  it "picks the global IPv4 address" do
    doc = { "network" => {
      "lo" => { "type" => "loopback", "addresses" => [{ "family" => "inet", "address" => "127.0.0.1", "scope" => "local" }] },
      "eth0" => { "type" => "broadcast", "addresses" => [
        { "family" => "inet6", "address" => "fd42::1", "scope" => "global" },
        { "family" => "inet", "address" => "10.0.0.5", "scope" => "global" },
      ] },
    } }
    expect(driver.send(:ip_address, doc)).to eq("10.0.0.5")
    expect(driver.send(:ip_address, { "network" => {} })).to be_nil
  end

  describe "#status" do
    it "reports not created without state" do
      expect(driver.status({})).to include(live: false, state: "not created")
    end

    it "reports running instances as live" do
      allow_any_instance_of(Kitchen::Incus::CLI).to receive(:state).and_return("status" => "Running")
      expect(driver.status(incus_instance: "x", incus_remote: "r")).to include(live: true, state: "running", resource_id: "r:x")
    end

    it "reports missing instances" do
      allow_any_instance_of(Kitchen::Incus::CLI).to receive(:state).and_return(nil)
      expect(driver.status(incus_instance: "x")).to include(live: false, state: "missing")
    end
  end

  describe "#destroy" do
    it "deletes the recorded instance on the recorded remote and clears state" do
      state = { incus_instance: "x", incus_remote: "r", incus_project: "p", hostname: "1.2.3.4" }
      expect_any_instance_of(Kitchen::Incus::CLI).to receive(:run)
        .with("delete", "--project", "p", "--force", "r:x", allow_failure: true).and_return(ok)
      driver.destroy(state)
      expect(state).to be_empty
    end

    it "ignores instances that are already gone" do
      allow_any_instance_of(Kitchen::Incus::CLI).to receive(:run)
        .and_return(Kitchen::Incus::CLI::Result.new("", "Error: Instance not found", 1))
      expect { driver.destroy(incus_instance: "x") }.not_to raise_error
    end

    it "is a no-op when nothing was created" do
      expect_any_instance_of(Kitchen::Incus::CLI).not_to receive(:run)
      driver.destroy({})
    end
  end
end
