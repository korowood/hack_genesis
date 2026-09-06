# frozen_string_literal: true

require "rack/test"
require "rspec"
require_relative "../lib/payout_router"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  config.example_status_persistence_file_path = ".rspec_status"
end

module FixtureHelpers
  def root = PayoutRouter::ROOT

  def config
    @config ||= PayoutRouter::Loaders.config(File.join(root, "config", "routing.yml"))
  end

  def providers
    PayoutRouter::Loaders.providers(File.join(root, "data", "providers.json"), config)
  end

  def operations
    PayoutRouter::Loaders.queue(File.join(root, "data", "operations_queue_10.json"))
  end

  def history
    PayoutRouter::Loaders.history(File.join(root, "data", "operations_history.csv"))
  end
end

RSpec.configure { |config| config.include FixtureHelpers }
