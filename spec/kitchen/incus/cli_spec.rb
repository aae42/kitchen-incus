# frozen_string_literal: true

require "spec_helper"

RSpec.describe Kitchen::Incus::CLI do
  let(:cli) { described_class.new(remote: "r1", project: "p1") }
  let(:ok) { Kitchen::Incus::CLI::Result.new("", "", 0) }

  it "prefixes targets with the remote" do
    expect(cli.target("box")).to eq("r1:box")
    expect(described_class.new.target("box")).to eq("box")
  end

  it "treats blank remote/project as unset" do
    c = described_class.new(remote: "", project: " ")
    expect(c.target("box")).to eq("box")
    expect(c.project_args).to eq([])
  end

  it "builds non-interactive exec args with project, user and env" do
    expect(cli.exec_args("box", user: 1000, env: { "A" => "b" }))
      .to eq(["exec", "--project", "p1", "-T", "--user", "1000", "--env", "A=b", "r1:box"])
  end

  it "uses -t for interactive exec" do
    expect(cli.exec_args("box", interactive: true)).to include("-t")
  end

  it "runs commands through sh -c without a local shell" do
    expect(cli).to receive(:run).with(
      "exec", "--project", "p1", "-T", "r1:box", "--", "sh", "-c", "echo 'hi'; ls"
    ).and_return(ok)
    cli.exec("box", "echo 'hi'; ls")
  end

  it "puts the project in the query URL" do
    expect(cli).to receive(:run).with("query", "r1:/1.0/instances/box/state?project=p1", anything)
      .and_return(Kitchen::Incus::CLI::Result.new('{"status":"Running"}', "", 0))
    expect(cli.state("box")).to eq("status" => "Running")
  end

  it "returns nil state for missing instances" do
    allow(cli).to receive(:run).and_return(Kitchen::Incus::CLI::Result.new("", "Error: Instance not found", 1))
    expect(cli.state("box")).to be_nil
  end

  it "raises on other query errors" do
    allow(cli).to receive(:run).and_return(Kitchen::Incus::CLI::Result.new("", "Error: TLS", 1))
    expect { cli.state("box") }.to raise_error(Kitchen::Incus::CommandFailed, /TLS/)
  end

  it "falls back to incus file push when the guest has no tar" do
    allow(cli).to receive(:exec).with("box", "command -v tar", anything)
      .and_return(Kitchen::Incus::CLI::Result.new("", "", 1))
    expect(cli).to receive(:run).with("file", "push", "--project", "p1", "-r", "-p",
      File.expand_path("/tmp/x"), "r1:box/tmp/kitchen/").and_return(ok)
    cli.push("box", "/tmp/x", "/tmp/kitchen")
  end

  it "raises CommandFailed with exit code on failure" do
    c = described_class.new(binary: "false")
    expect { c.run("x") }.to raise_error(Kitchen::Incus::CommandFailed) { |e| expect(e.exit_code).to eq(1) }
  end

  it "reports a missing binary" do
    c = described_class.new(binary: "definitely-not-incus-xyz")
    expect { c.run("version") }.to raise_error(Kitchen::Incus::CommandFailed, /not found/)
  end
end
