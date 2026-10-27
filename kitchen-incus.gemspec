# frozen_string_literal: true

require_relative "lib/kitchen/incus/version"

Gem::Specification.new do |spec|
  spec.name          = "kitchen-incus"
  spec.version       = Kitchen::Incus::VERSION
  spec.authors       = ["Andrew Brossia"]
  spec.email         = ["abrossia@gmail.com"]
  spec.summary       = "Test Kitchen driver and transport for Incus containers and VMs"
  spec.description   = "Runs Test Kitchen instances as Incus containers or virtual machines, " \
                       "using the incus CLI for exec, file transfer, login and InSpec verification."
  spec.license       = "Apache-2.0"
  spec.required_ruby_version = ">= 3.1"

  spec.files         = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "test-kitchen", ">= 3.0", "< 5"
  # Cinc is the default Chef Infra distribution: kitchen-cinc provides the
  # cinc_* provisioners and points chef_* provisioner names at Cinc.
  spec.add_dependency "kitchen-cinc", ">= 1.0"
  spec.add_dependency "mixlib-shellout", ">= 3.0"

  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", "~> 3.0"
end
