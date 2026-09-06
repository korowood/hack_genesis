# frozen_string_literal: true

module PayoutRouter
  module CLI
    DEFAULTS = {
      queue: File.join(ROOT, "data", "operations_queue_10.json"),
      providers: File.join(ROOT, "data", "providers.json"),
      history: File.join(ROOT, "data", "operations_history.csv"),
      config: File.join(ROOT, "config", "routing.yml"),
      profile: "submission",
      output: File.join(ROOT, "routing_decisions.json"),
      report: File.join(ROOT, "routing_report.json")
    }.freeze

    module_function

    def route(argv, forced_outcomes: {})
      options = DEFAULTS.dup
      parser = OptionParser.new do |opts|
        opts.banner = "Использование: bin/route [опции]"
        opts.on("--queue PATH") { |value| options[:queue] = value }
        opts.on("--providers PATH") { |value| options[:providers] = value }
        opts.on("--history PATH") { |value| options[:history] = value }
        opts.on("--config PATH") { |value| options[:config] = value }
        opts.on("--profile NAME") { |value| options[:profile] = value }
        opts.on("--output PATH") { |value| options[:output] = value }
        opts.on("--report PATH") { |value| options[:report] = value }
        opts.on("--forced-outcomes PATH") { |value| forced_outcomes = Loaders.json(value) }
      end
      parser.parse!(argv)
      run, operations, config, history = execute(options, forced_outcomes)
      decisions = run.to_a
      validate_decisions!(decisions, operations)
      write_json(options[:output], decisions)
      report = ReportBuilder.new(
        run: run, operations: operations, config: config, history_rows: history
      ).build
      write_json(options[:report], report)
      puts "Готово: #{options[:output]}"
      puts "Отчёт:  #{options[:report]}"
      [run, report]
    rescue Error, OptionParser::ParseError => e
      warn "Ошибка: #{e.message}"
      exit 1
    end

    def report(argv)
      options = DEFAULTS.dup
      OptionParser.new do |opts|
        opts.banner = "Использование: bin/report [опции]"
        opts.on("--queue PATH") { |value| options[:queue] = value }
        opts.on("--providers PATH") { |value| options[:providers] = value }
        opts.on("--history PATH") { |value| options[:history] = value }
        opts.on("--config PATH") { |value| options[:config] = value }
        opts.on("--profile NAME") { |value| options[:profile] = value }
        opts.on("--output PATH") { |value| options[:report] = value }
      end.parse!(argv)
      run, operations, config, history = execute(options, {})
      payload = ReportBuilder.new(
        run: run, operations: operations, config: config, history_rows: history
      ).build
      write_json(options[:report], payload)
      puts "Отчёт: #{options[:report]}"
      payload
    rescue Error, OptionParser::ParseError => e
      warn "Ошибка: #{e.message}"
      exit 1
    end

    def demo(argv)
      forced = {
        "op_101" => {
          "vipay" => "rejected",
          "payflow" => "expired",
          "quickpay" => "rejected"
        }
      }
      route(
        ["--profile", "balanced",
         "--output", File.join(ROOT, "demo_decisions.json"),
         "--report", File.join(ROOT, "demo_report.json")] + argv,
        forced_outcomes: forced
      )
    end

    def execute(options, forced_outcomes)
      config = Loaders.config(options[:config])
      operations = Loaders.queue(options[:queue])
      providers = Loaders.providers(options[:providers], config)
      history = Loaders.history(options[:history])
      run = Router.new(
        providers: providers, config: config, history_rows: history,
        profile: options[:profile], forced_outcomes: forced_outcomes
      ).route(operations)
      [run, operations, config, history]
    end

    def validate_decisions!(decisions, operations)
      raise InputError, "Число решений не совпадает с числом операций" unless decisions.size == operations.size

      ids = decisions.map { |decision| decision["operation_id"] }
      raise InputError, "В решениях есть дубли operation_id" unless ids.uniq.size == ids.size

      missing = operations.map(&:id) - ids
      raise InputError, "Нет решений для: #{missing.join(', ')}" if missing.any?

      decisions.each do |decision|
        %w[operation_id selected_provider attempts simulated_result].each do |field|
          raise InputError, "#{decision['operation_id']}: отсутствует #{field}" unless decision.key?(field)
        end
        raise InputError, "#{decision['operation_id']}: attempts должен быть массивом" unless decision["attempts"].is_a?(Array)
        decision["attempts"].each do |attempt|
          %w[provider decision reason].each do |field|
            raise InputError, "#{decision['operation_id']}: attempt без #{field}" unless attempt.key?(field)
          end
        end
      end
    end

    def write_json(path, payload)
      directory = File.dirname(File.expand_path(path))
      raise InputError, "Каталог результата не существует: #{directory}" unless Dir.exist?(directory)

      temporary = "#{path}.tmp.#{$PROCESS_ID || Process.pid}"
      File.write(temporary, JSON.pretty_generate(payload) + "\n")
      File.rename(temporary, path)
    ensure
      File.delete(temporary) if temporary && File.exist?(temporary)
    end
  end
end
