# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kitchen::Transport::Incus do
  let(:instance) do
    double("instance", name: "i", to_str: "<i>", logger: Kitchen::Logger.new(stdout: StringIO.new),
      verifier: double("verifier"))
  end
  let(:transport) { described_class.new({}).finalize_config!(instance) }
  let(:state) { { incus_instance: "box", incus_remote: "r", incus_project: "p" } }
  let(:conn) { transport.connection(state) }

  it "requires a created instance" do
    expect { transport.connection({}) }.to raise_error(Kitchen::ActionFailed, /kitchen create/)
  end

  it "builds an interactive login command" do
    lc = conn.login_command
    expect(lc.command).to eq("incus")
    expect(lc.arguments).to eq(["exec", "--project", "p", "-t", "r:box", "--", "su", "-l"])
  end

  it "raises TransportFailed with the exit code when a command fails" do
    allow_any_instance_of(Kitchen::Incus::CLI).to receive(:exec)
      .and_raise(Kitchen::Incus::CommandFailed.new("boom", 42))
    expect { conn.execute("false") }.to raise_error(Kitchen::Transport::TransportFailed) { |e| expect(e.exit_code).to eq(42) }
  end

  it "skips empty commands" do
    expect_any_instance_of(Kitchen::Incus::CLI).not_to receive(:exec)
    conn.execute(nil)
  end
end
