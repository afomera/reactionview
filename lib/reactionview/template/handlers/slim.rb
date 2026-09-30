# frozen_string_literal: true

module ReActionView
  class Template
    module Handlers
      # Compiles `.slim` templates with Herb, turned on with `config.intercept_slim`.
      #
      # Herb parses the Slim into the same HTML+ERB tree it builds for ERB, so a Slim template goes
      # through `Handlers::Herb` like any other: the validators and overlays, debug mode, the dev
      # tools in a layout's `<head>`, registered visitors and reactive templates (slots).
      #
      # It mirrors `Handlers::ERB`. Templates in the `html` and `slots` formats are intercepted, and
      # everything else, like a mailer's `.text.slim`, keeps the handler `:slim` had before (the
      # Slim gem's, when it's installed). Gem templates follow `config.external_template_mode`,
      # falling back to that handler too.
      class Slim
        include ReActionView::Template::LocalTemplate

        INTERCEPTED_FORMATS = [:html, ::ReActionView::Slots::FORMAT].freeze

        # The handler `:slim` was registered with before ReActionView took it over, or nil.
        attr_reader :fallback

        def initialize(fallback: nil)
          @fallback = fallback
        end

        def call(template, source = nil)
          source ||= template.source

          return fallback_call(template, source) if skip_template?(template)

          ::ReActionView::Template::Handlers::Herb.call(
            template, source, validation_mode: herb_validation_mode(template), language: "slim"
          )
        rescue ::Herb::Engine::CompilationError, StandardError => e
          raise unless fallback && fall_back?(template)

          log_external_template_error(template, e)

          fallback_call(template, source)
        end

        def supports_streaming?
          true
        end

        private

        def fallback_call(template, source)
          unless fallback
            raise ArgumentError, "#{template.identifier} is not compiled by ReActionView, and no other handler is registered for `.slim`"
          end

          fallback.call(template, source)
        end

        def skip_template?(template)
          return false unless fallback
          return true unless INTERCEPTED_FORMATS.include?(template.format)
          return true if framework_template?(template)
          return false if local_template?(template)

          ReActionView.config.external_template_mode == :skip
        end

        def herb_validation_mode(template)
          return nil unless fallback
          return nil if local_template?(template)
          return nil unless ReActionView.config.external_template_mode == :fallback

          :raise
        end

        def fall_back?(template)
          !local_template?(template) && ReActionView.config.external_template_mode == :fallback
        end

        def log_external_template_error(template, error)
          return unless defined?(Rails.logger) && Rails.logger

          Rails.logger.warn(
            "[ReActionView] #{template.identifier} could not be compiled by Herb, " \
            "falling back to #{fallback.class}: #{error.message.strip.lines.first}"
          )
        end
      end
    end
  end
end
