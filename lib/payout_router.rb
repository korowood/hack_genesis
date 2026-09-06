# frozen_string_literal: true

require "csv"
require "date"
require "digest"
require "json"
require "optparse"
require "time"
require "yaml"

module PayoutRouter
  class Error < StandardError; end
  class InputError < Error; end

  ROOT = File.expand_path("..", __dir__)
end

require_relative "payout_router/models"
require_relative "payout_router/loaders"
require_relative "payout_router/constraints"
require_relative "payout_router/state_tracker"
require_relative "payout_router/history_analyzer"
require_relative "payout_router/strategies"
require_relative "payout_router/simulator"
require_relative "payout_router/router"
require_relative "payout_router/report_builder"
require_relative "payout_router/optimizer"
require_relative "payout_router/cli"
