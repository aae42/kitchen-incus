# frozen_string_literal: true

require "kitchen"
require "kitchen/incus/cli"
require "kitchen/driver/incus"
require "kitchen/transport/incus"

RSpec.configure do |c|
  c.disable_monkey_patching!
end
