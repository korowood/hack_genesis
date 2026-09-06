# frozen_string_literal: true

module PayoutRouter
  module Constraints
    class Base
      private

      def allow = ConstraintResult.new(allowed: true)

      def deny(reason, details)
        ConstraintResult.new(allowed: false, reason: reason, details: details)
      end
    end

    class Status < Base
      def call(_operation, provider, _state, _config)
        return allow if provider["status"] == "active"

        deny("provider_inactive", "status=#{provider['status'].inspect}, требуется active")
      end
    end

    class TrafficAvailability < Base
      def call(_operation, provider, _state, config)
        hard = config.dig("validator_compatibility", "zero_traffic_is_hard")
        return allow unless hard && provider["traffic_percentage"].to_f.zero?
        return allow if provider.id == config.fetch("fallback_provider", "spacepayments")

        deny("zero_traffic", "traffic_percentage=0")
      end
    end

    class AmountRange < Base
      def call(operation, provider, _state, _config)
        min = provider["limit_amount_min"]
        max = provider["limit_amount_max"]
        return deny("amount_below_minimum", "#{operation.amount} < limit_amount_min #{min}") if min && operation.amount < min
        return deny("amount_exceeds_limit", "#{operation.amount} > limit_amount_max #{max}") if max && operation.amount > max

        allow
      end
    end

    class DailyLimit < Base
      def call(operation, provider, state, _config)
        limit = provider["daily_amount_limit"]
        projected = state.daily_approved(provider.id) + operation.amount
        return allow unless limit && projected > limit

        deny("daily_limit_exceeded", "#{projected.round(2)} > daily_amount_limit #{limit}")
      end
    end

    class TurnoverMax < Base
      def call(operation, provider, state, _config)
        maximum = provider["daily_turnover_max"]
        return allow if maximum.nil?

        projected = state.daily_approved(provider.id) + operation.amount
        return allow unless projected > maximum.to_f

        deny(
          "daily_turnover_max_exceeded",
          "#{projected.round(2)} > daily_turnover_max #{maximum}"
        )
      end
    end

    class InProgress < Base
      def call(operation, provider, state, _config)
        count_limit = provider["in_progress_count_limit"]
        amount_limit = provider["in_progress_amount_limit"]
        projected_count = state.in_progress_count(provider.id) + 1
        projected_amount = state.in_progress_amount(provider.id) + operation.amount

        if count_limit && projected_count > count_limit
          return deny("in_progress_count_exceeded", "#{projected_count} > in_progress_count_limit #{count_limit}")
        end
        if amount_limit && projected_amount > amount_limit
          return deny("in_progress_amount_exceeded", "#{projected_amount.round(2)} > in_progress_amount_limit #{amount_limit}")
        end

        allow
      end
    end

    class Bank < Base
      def call(operation, provider, _state, _config)
        banks = provider["banks"] || []
        return allow if banks.empty?

        excluded = provider["exclude_banks"] ? banks.include?(operation.bank) : !banks.include?(operation.bank)
        return allow unless excluded

        mode = provider["exclude_banks"] ? "исключён списком" : "отсутствует в разрешённом списке"
        deny("bank_not_in_list", "#{operation.bank} #{mode} #{banks.join(', ')}")
      end
    end

    class Margin < Base
      def call(_operation, provider, _state, _config)
        provider_margin = provider["provider_margin_pct"].to_f
        merchant_margin = provider["merchant_margin_pct"].to_f
        allowed_negative = provider["allow_negative_agreement"]
        return allow if provider_margin <= merchant_margin || allowed_negative

        deny("negative_margin", "#{provider_margin}% > merchant_margin_pct #{merchant_margin}%")
      end
    end

    class Requisites < Base
      def call(_operation, provider, _state, _config)
        return allow unless provider["available_requisites"].to_i.zero?

        deny("no_requisites", "available_requisites=0")
      end
    end

    class RateLimit < Base
      def call(operation, provider, state, _config)
        limit = provider["requests_per_minute_limit"]
        return allow unless limit

        current = state.requests_last_minute(provider.id, operation.created_at)
        return allow if current + 1 <= limit

        deny("rate_limit_exceeded", "#{current + 1} > requests_per_minute_limit #{limit}")
      end
    end

    class Chain
      DEFAULTS = [
        Status, TrafficAvailability, AmountRange, DailyLimit, TurnoverMax, InProgress,
        Bank, Margin, Requisites, RateLimit
      ].freeze

      def initialize(filters: DEFAULTS)
        @filters = filters.map(&:new)
      end

      def evaluate(operation, provider, state, config)
        @filters.each do |filter|
          result = filter.call(operation, provider, state, config)
          return result unless result.allowed?
        end
        ConstraintResult.new(allowed: true)
      end
    end
  end
end
