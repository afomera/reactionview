# frozen_string_literal: true

module ReActionView
  class Template
    # The language a template is written in, from its path: `"slim"` for a `.slim` file and
    # `"erb"` for everything else, the way Herb chooses it.
    def self.language_for(path)
      return "erb" if path.nil?
      return ::Herb::TemplateLanguage.for_path(path) if defined?(::Herb::TemplateLanguage)

      path.to_s.downcase.end_with?(".slim") ? "slim" : "erb"
    end

    # Whether the installed Herb compiles Slim templates.
    def self.slim_supported?
      require "herb/engine"

      !!(defined?(::Herb::Engine::LANGUAGES) && ::Herb::Engine::LANGUAGES.include?("slim"))
    end
  end
end
