# frozen_string_literal: true

require "herb"
require "herb/engine"
require "herb/engine/slots/dynamics_compiler"
require "herb/engine/slots/schema_compiler"

require "herb/engine/visitors/debug_visitor"
require "herb/engine/slots/visitor"
require "herb/engine/slots/dependencies"
require "herb/engine/visitors/content_for_visitor"
require "herb/engine/validators"

module ReActionView
  class Template
    module Handlers
      class Herb < ActionView::Template::Handlers::ERB
        include ReActionView::Template::LocalTemplate

        autoload :Herb, "reactionview/template/handlers/herb/herb"

        class_attribute :erb_implementation, default: Handlers::Herb::Herb

        VALUES_ESCAPING = {
          escape: true,
          escapefunc: "::ERB::Util.h",
          attrfunc: nil,
          jsfunc: nil,
          cssfunc: nil,
        }.freeze

        def self.call(template, source, validation_mode: nil, language: nil)
          new.call(template, source, validation_mode: validation_mode, language: language)
        end

        def self.compile_for_dependencies(source, path)
          new.compile_for_dependencies(source, path)
        end

        def self.compile_for_schema(source, path)
          new.compile_for_schema(source, path)
        end

        def self.compile_for_block(source, path, index)
          new.compile_for_block(source, path, index)
        end

        # `language` is the language the source is written in, `"erb"` or `"slim"`. It defaults to
        # the one the template's path names, so a `.html.slim` template compiles as Slim.
        def call(template, source, validation_mode: nil, language: nil)
          @language = language&.to_s
          mode = validation_mode || ReActionView.config.validation_mode

          visitors = base_visitors(template, validation_mode: mode)

          config = {
            filename: translate_path_for_editor(template.identifier),
            project_path: ::ReActionView.config.project_path,
            visitors: visitors,
            **engine_options,
            **language_option(template),
          }

          return values_source(template, source, config) if values_format?(template)

          slots = slot_visitors(template, source)

          config[:visitors] = compile_stack(template, validation_mode: mode, slots: slots)

          erb_implementation.new(source, config).src
        end

        def compile_for_dependencies(source, path)
          template = ::Struct.new(:identifier, :format).new(path, :html)
          visitor = slot_visitors(template, source, mark: false).first

          return nil unless visitor

          erb_implementation.new(
            source,
            filename: translate_path_for_editor(path),
            project_path: ::ReActionView.config.project_path,
            visitors: [*base_visitors(template), visitor],
            **engine_options,
            **language_option(template)
          ).src

          visitor
        end

        def compile_for_block(source, path, index)
          template = ::Struct.new(:identifier, :format).new(path, :html)
          visitor = slot_visitors(template, source, mark: false).first

          return nil unless visitor

          ::Herb::Engine::Slots::DynamicsCompiler.new(
            source,
            filename: translate_path_for_editor(path),
            project_path: ::ReActionView.config.project_path,
            visitors: base_visitors(template),
            slot_visitor: visitor,
            block: index,
            **engine_options,
            **language_option(template),
            **VALUES_ESCAPING
          ).src
        end

        def compile_for_schema(source, path)
          template = ::Struct.new(:identifier, :format).new(path, :html)

          ::Herb::Engine::Slots::SchemaCompiler.call(
            source,
            filename: translate_path_for_editor(path),
            mode: ::ReActionView.config.slot_mode_for(source, language: language_of(template)),
            visitors: -> { base_visitors(template, validation_mode: schema_validation_mode) },
            engine: erb_implementation,
            options: { project_path: ::ReActionView.config.project_path, **engine_options, **language_option(template) }
          )
        end

        private

        def base_visitors(template, validation_mode: ReActionView.config.validation_mode)
          compile_stack(template, validation_mode: validation_mode).reject { |visitor| rewrites_erb_source?(visitor) }
        end

        def compile_stack(template, validation_mode:, slots: [])
          visitors = [
            *validation_visitors(validation_mode),
            *debug_visitors(template),
            *head_visitors(template),
            *slots,
            *::ReActionView.config.engine.visitors
          ]

          ::Herb::Visitor::Stack.arrange(visitors)
        end

        def engine_options
          configured = ::ReActionView.config.engine.parser_options
          options = resolver_option

          return options if configured.empty?

          defaults = ::Herb.configuration.engine_option("parser_options", {})

          options.merge(parser_options: defaults.transform_keys(&:to_sym).merge(configured))
        end

        # The language the template compiles as: the one `call` was given, or the one its path names.
        def language_of(template)
          return @language if @language

          ReActionView::Template.language_for(template.respond_to?(:identifier) ? template.identifier : nil)
        end

        # Tells the engine the template is Slim. ERB templates compile with the options they always
        # have, so an engine that predates Slim sees nothing new.
        def language_option(template)
          language = language_of(template)

          language == "erb" ? {} : { language: language }
        end

        def resolver_option
          return {} unless defined?(::Herb::Analysis::PartialResolver)

          { resolver: ::ReActionView::Template::PartialResolver.current }
        end

        def rewrites_erb_source?(visitor)
          klass = visitor.class

          klass.respond_to?(:rewrites_erb_source?) && klass.rewrites_erb_source?
        end

        def schema_validation_mode
          ReActionView.config.validation_mode == :none ? :none : :overlay
        end

        def values_source(template, source, config)
          visitor = slot_visitors(template, source, mark: false).first

          return "{}" unless visitor

          ::Herb::Engine::Slots::DynamicsCompiler.new(source, config.merge(slot_visitor: visitor, **VALUES_ESCAPING)).src
        end

        def values_format?(template)
          template.respond_to?(:format) && template.format == :slots
        end

        def validation_visitors(mode)
          case mode
          when :raise then ::Herb::Engine::Validators.all(fatal: true).to_a
          when :overlay then ::Herb::Engine::Validators.all(fatal: false).to_a
          else []
          end
        end

        def debug_visitors(template)
          return [] unless ::ReActionView.config.debug_mode_enabled? && local_template?(template)

          [::Herb::Engine::DebugVisitor.new]
        end

        def head_visitors(template)
          markup = reactionview_dev_tools_markup(template)

          return [] if markup.nil? || markup.empty?

          [::Herb::Engine::ContentForVisitor.new(markup, tag_name: "head")]
        end

        def slot_visitors(template, source, mark: true)
          return [] unless values_format?(template) || (template.respond_to?(:format) && template.format == :html)

          mode = ::ReActionView.config.slot_mode_for(source, language: language_of(template))

          return [] unless mode

          [::Herb::Engine::Slots::Visitor.new(mode: mode, mark: mark)]
        end

        def layout_template?(template)
          return false unless template.respond_to?(:identifier) && template.identifier

          template.identifier.include?("/layouts/")
        end

        def active_support_editor
          return unless defined?(ActiveSupport::Editor)
          return if ActiveSupport::Editor.current.blank?

          ActiveSupport::Editor.current.instance_variable_get(:@url_pattern).split("://").first
        end

        def translate_path_for_editor(template_path)
          rails_root = Rails.root.to_s
          project_path = ::ReActionView.config.project_path

          return template_path if project_path == rails_root

          template_path.to_s.sub(rails_root, project_path)
        end

        def editor_meta_tag
          editor_name = active_support_editor || ENV["RAILS_EDITOR"] || ENV.fetch("EDITOR", nil)

          return if editor_name.blank?

          %(<meta name="herb-default-editor" content="#{editor_name}">)
        end

        def dev_server_port_meta_tag
          port = ::ReActionView.config.dev_server_port

          return if port.blank?

          %(<meta name="herb-dev-server-port" content="#{port}">)
        end

        def reactionview_dev_tools_markup(template)
          return nil unless layout_template?(template)
          return nil unless local_template?(template)
          return slots_meta_markup unless ::ReActionView.config.debug_mode_enabled?

          <<~HTML
            <meta name="herb-debug-mode" content="true">
            <meta name="herb-project-path" content="#{Rails.root}">
            #{dev_server_port_meta_tag}
            #{editor_meta_tag}

            #{ActionController::Base.new.view_context.javascript_include_tag "reactionview-dev-tools.umd.js", defer: true}
            #{dismiss_hint_template}
          HTML
        end

        def slots_meta_markup
          return nil unless ::ReActionView.config.slots && ::ReActionView.config.development?

          <<~HTML
            <meta name="herb-project-path" content="#{Rails.root}">
            #{dev_server_port_meta_tag}
          HTML
        end

        def dismiss_hint_template
          return unless ::ReActionView.config.validation_mode == :overlay

          <<~HTML.chomp
            <template data-herb-dismiss-hint>You can also disable this overlay by setting <code style="color: #ffeb3b; font-family: monospace; font-size: 12pt;">config.validation_mode = :none</code> in <code style="color: #ffeb3b; font-family: monospace; font-size: 12pt;">config/initializers/reactionview.rb</code>.</template>
          HTML
        end
      end
    end
  end
end
