# frozen_string_literal: true

module PayoutRouter
  module Loaders
    module_function

    def json(path)
      JSON.parse(File.read(path))
    rescue Errno::ENOENT
      raise InputError, "Файл не найден: #{path}"
    rescue JSON::ParserError => e
      raise InputError, "Невалидный JSON #{path}: #{e.message}"
    end

    def queue(path)
      rows = json(path)
      raise InputError, "Очередь должна быть JSON-массивом" unless rows.is_a?(Array)

      operations = rows.map { |row| Operation.from_h(row) }
      duplicates = operations.group_by(&:id).select { |_id, values| values.size > 1 }.keys
      raise InputError, "Дубли operation_id: #{duplicates.join(', ')}" if duplicates.any?

      operations.sort_by(&:created_at)
    end

    def providers(path, config = {})
      payload = json(path)
      rows = payload["providers"]
      raise InputError, "providers.json должен содержать массив providers" unless rows.is_a?(Array)

      extensions = config.fetch("provider_extensions", {})
      rows.map { |row| Provider.from_h(row).with_extensions(extensions[row["payment_system"]]) }
    end

    def history(path)
      return [] unless path && File.exist?(path)

      CSV.read(path, headers: true).map(&:to_h)
    rescue CSV::MalformedCSVError => e
      raise InputError, "Невалидный CSV #{path}: #{e.message}"
    end

    def config(path)
      data = YAML.safe_load(File.read(path), aliases: false)
      raise InputError, "Конфигурация должна быть объектом" unless data.is_a?(Hash)

      data
    rescue Errno::ENOENT
      raise InputError, "Файл конфигурации не найден: #{path}"
    rescue Psych::SyntaxError => e
      raise InputError, "Невалидный YAML #{path}: #{e.message}"
    end

    def decisions(path)
      rows = json(path)
      rows = [rows] unless rows.is_a?(Array)
      rows
    end
  end
end
