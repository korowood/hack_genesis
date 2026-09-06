# frozen_string_literal: true

module PayoutRouter
  class ReportBuilder
    def initialize(run:, operations:, config:, history_rows: [])
      @run = run
      @operations = operations
      @config = config
      @history = HistoryAnalyzer.new(history_rows)
      @operation_by_id = operations.to_h { |operation| [operation.id, operation] }
    end

    def build
      decisions = @run.decisions
      recommendation_rows = recommendations
      {
        "period" => report_period,
        "profile" => @run.profile,
        "total_operations" => decisions.size,
        "success_rate_pct" => percentage(decisions.count { |decision| decision.simulated_result == "approved" }, decisions.size),
        "distribution" => distribution,
        "volume_distribution" => volume_distribution,
        "outcomes" => counts(decisions.map(&:simulated_result)),
        "skip_reasons" => skip_reasons,
        "projected_daily_utilization" => utilization,
        "provider_history_metrics" => @history.all_metrics(@run.providers),
        "routing_quality" => routing_quality,
        "goal_impossibility" => goal_impossibility,
        "deviation_causes" => deviation_causes,
        "recommendations" => recommendation_rows,
        "recommendation_messages" => recommendation_rows.map { |row| recommendation_message(row) }
      }
    end

    private

    def distribution
      total = @run.decisions.size
      selected = counts(@run.decisions.map(&:selected_provider))
      @run.providers.to_h do |provider|
        actual = percentage(selected.fetch(provider.id, 0), total)
        target = provider["traffic_percentage"].to_f
        [
          provider.id,
          {
            "count" => selected.fetch(provider.id, 0),
            "share_pct" => actual,
            "target_pct" => target,
            "deviation_pct_points" => (actual - target).round(2)
          }
        ]
      end
    end

    def volume_distribution
      total = @run.decisions.sum { |decision| @operation_by_id.fetch(decision.operation_id).amount }
      volumes = Hash.new(0.0)
      @run.decisions.each do |decision|
        volumes[decision.selected_provider] += @operation_by_id.fetch(decision.operation_id).amount
      end
      @run.providers.to_h do |provider|
        target = provider["volume_share_pct"].to_f
        share = total.positive? ? (volumes[provider.id] / total * 100).round(2) : 0.0
        [
          provider.id,
          {
            "amount" => volumes[provider.id].round(2),
            "share_pct" => share,
            "target_pct" => target,
            "deviation_pct_points" => (share - target).round(2)
          }
        ]
      end
    end

    def skip_reasons
      counts(
        @run.decisions.flat_map(&:attempts)
          .select { |attempt| attempt.decision == "skipped" }
          .map(&:reason)
      )
    end

    def utilization
      @run.providers.to_h do |provider|
        used = @run.state.daily_approved(provider.id)
        limit = provider["daily_amount_limit"]
        turnover_max = provider["daily_turnover_max"]
        utilization_pct = limit.to_f.positive? ? (used / limit.to_f * 100).round(2) : nil
        turnover_max_pct = turnover_max.to_f.positive? ? (used / turnover_max.to_f * 100).round(2) : nil
        [
          provider.id,
          {
            "used" => used.round(2),
            "limit" => limit,
            "utilization_pct" => utilization_pct,
            "daily_turnover_max" => turnover_max,
            "turnover_max_utilization_pct" => turnover_max_pct,
            "in_progress_count" => @run.state.in_progress_count(provider.id),
            "in_progress_amount" => @run.state.in_progress_amount(provider.id).round(2)
          }
        ]
      end
    end

    def routing_quality
      deviations = distribution.values.reject { |row| row["target_pct"].zero? }
      mean_abs_deviation = if deviations.empty?
                             0.0
                           else
                             deviations.sum { |row| row["deviation_pct_points"].abs } / deviations.size
                           end
      retries = @run.decisions.sum do |decision|
        [decision.attempts.count { |attempt| attempt.decision == "selected" } - 1, 0].max
      end
      {
        "mean_absolute_target_deviation_pct_points" => mean_abs_deviation.round(2),
        "retry_count" => retries,
        "fallback_count" => @run.decisions.count { |decision| decision.selected_provider == @config["fallback_provider"] },
        "unavailable_target_events" => goal_impossibility["events"],
        "explainability_coverage_pct" => percentage(
          @run.decisions.count { |decision| decision.attempts.all? { |attempt| attempt.reason && attempt.details } },
          @run.decisions.size
        )
      }
    end

    def goal_impossibility
      events = @run.decisions.flat_map { |decision| decision.goal_unavailable || [] }
      {
        "events" => events.size,
        "by_provider" => counts(events.map { |event| event["provider"] }),
        "by_blocking_reason" => counts(events.map { |event| event["blocking_reason"] }),
        "examples" => events.first(5)
      }
    end

    def deviation_causes
      causes = []
      skips_by_provider = Hash.new { |hash, key| hash[key] = Hash.new(0) }
      @run.decisions.each do |decision|
        decision.attempts.select { |attempt| attempt.decision == "skipped" }.each do |attempt|
          skips_by_provider[attempt.provider][attempt.reason] += 1
        end
      end

      distribution.each do |provider_id, row|
        next unless row["target_pct"].positive? && row["deviation_pct_points"].abs >= 10

        util = utilization.fetch(provider_id)
        top_skip = skips_by_provider[provider_id].max_by { |_reason, count| count }
        direction = row["deviation_pct_points"].positive? ? "выше цели" : "ниже цели"
        reasons = []
        if row["deviation_pct_points"].negative? && top_skip
          reasons << "часто отсекался hard-фильтром #{top_skip[0]} (#{top_skip[1]} раз)"
        end
        if util["utilization_pct"] && util["utilization_pct"] >= 80
          reasons << "дневной лимит загружен на #{util['utilization_pct']}%"
        end
        if util["turnover_max_utilization_pct"] && util["turnover_max_utilization_pct"] >= 80
          reasons << "daily_turnover_max загружен на #{util['turnover_max_utilization_pct']}%"
        end
        only_eligible = @run.decisions.count do |decision|
          decision.selected_provider == provider_id &&
            decision.attempts.any? { |attempt| attempt.reason == "only_eligible_provider" }
        end
        if row["deviation_pct_points"].positive? && only_eligible.positive?
          reasons << "получил #{only_eligible} заявок как единственный eligible"
        end
        reasons << "мягкий сдвиг soft-scoring по активному профилю" if reasons.empty?

        causes << {
          "provider" => provider_id,
          "metric" => "count_share",
          "actual_pct" => row["share_pct"],
          "target_pct" => row["target_pct"],
          "deviation_pct_points" => row["deviation_pct_points"],
          "summary" => "#{provider_id} #{direction} на #{row['deviation_pct_points'].abs} п.п.",
          "reasons" => reasons
        }
      end

      volume_distribution.each do |provider_id, row|
        next unless row["target_pct"].positive? && row["deviation_pct_points"].abs >= 10
        next if causes.any? { |cause| cause["provider"] == provider_id && cause["metric"] == "count_share" }

        causes << {
          "provider" => provider_id,
          "metric" => "volume_share",
          "actual_pct" => row["share_pct"],
          "target_pct" => row["target_pct"],
          "deviation_pct_points" => row["deviation_pct_points"],
          "summary" => "#{provider_id} отклонился по объёму на #{row['deviation_pct_points']} п.п.",
          "reasons" => ["перераспределение крупных чеков и amount_band / hard amount limits"]
        }
      end

      causes
    end

    def recommendations
      messages = []
      distribution.each do |provider_id, row|
        next unless row["target_pct"].positive? && row["deviation_pct_points"].abs >= 15

        direction = row["deviation_pct_points"].positive? ? "снизить" : "повысить"
        proposed = [[row["target_pct"] - row["deviation_pct_points"] * 0.25, 5].max, 80].min.round
        messages << {
          "provider" => provider_id,
          "action" => "#{direction} приоритет traffic_count",
          "parameter" => "traffic_percentage",
          "current_value" => row["target_pct"],
          "proposed_value" => proposed,
          "evidence" => "Отклонение фактической доли #{row['deviation_pct_points']} п.п."
        }
      end

      utilization.each do |provider_id, row|
        next unless row["utilization_pct"] && row["utilization_pct"] >= 80

        messages << {
          "provider" => provider_id,
          "action" => "снизить трафик и усилить load penalty",
          "parameter" => "strategy_weights.load",
          "current_value" => @config.dig("profiles", @run.profile, "weights", "load"),
          "proposed_value" => 0.30,
          "evidence" => "Дневной лимит использован на #{row['utilization_pct']}%"
        }
      end

      utilization.each do |provider_id, row|
        next unless row["turnover_max_utilization_pct"] && row["turnover_max_utilization_pct"] >= 90

        messages << {
          "provider" => provider_id,
          "action" => "ослабить нагрузку до исчерпания daily_turnover_max",
          "parameter" => "daily_turnover_max",
          "current_value" => row["daily_turnover_max"],
          "proposed_value" => row["daily_turnover_max"],
          "evidence" => "Оборотное обязательство max использовано на #{row['turnover_max_utilization_pct']}%"
        }
      end

      if goal_impossibility["events"].positive?
        top = goal_impossibility["by_provider"].max_by { |_provider, count| count }
        messages << {
          "provider" => top.first,
          "action" => "пересмотреть banks/limits или снизить traffic_percentage недоступного канала",
          "parameter" => "traffic_percentage",
          "current_value" => distribution.dig(top.first, "target_pct"),
          "proposed_value" => [[distribution.dig(top.first, "target_pct").to_f - 10, 5].max, 80].min.round,
          "evidence" => "Целевой провайдер был недоступен #{top.last} раз(а)"
        }
      end

      if messages.empty?
        messages << {
          "provider" => "all",
          "action" => "сохранить текущую конфигурацию",
          "parameter" => "profile",
          "current_value" => @run.profile,
          "proposed_value" => @run.profile,
          "evidence" => "Существенных отклонений и рисков лимитов не обнаружено"
        }
      end
      messages
    end

    def recommendation_message(row)
      "#{row['provider']}: #{row['action']} " \
        "(#{row['parameter']}: #{row['current_value']} → #{row['proposed_value']}). " \
        "#{row['evidence']}"
    end

    def report_period
      @operations.first&.created_at&.to_date&.iso8601 || Date.today.iso8601
    end

    def counts(values)
      values.compact.each_with_object(Hash.new(0)) { |value, result| result[value] += 1 }.to_h
    end

    def percentage(value, total)
      total.to_i.zero? ? 0.0 : (value.to_f / total * 100).round(2)
    end
  end
end
