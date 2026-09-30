# frozen_string_literal: true

require_relative "../../test_helper"

require "action_controller"

class ReActionView::SlimHandlerTest < Minitest::Spec
  RAILS_ROOT = "/app"
  VIEW = "/app/app/views/users/show.html.slim"
  LAYOUT = "/app/app/views/layouts/application.html.slim"
  EXTERNAL = "/gems/devise-4.9.4/app/views/devise/sessions/new.html.slim"

  VIEW_SOURCE = <<~'SLIM'
    div.card
      h1 Hello #{@name}
      p.lead title="x" = @message
      - if @admin
        span.badge Admin
  SLIM

  LAYOUT_SOURCE = <<~SLIM
    doctype html
    html
      head
        title App
      body
        == yield
  SLIM

  class FallbackHandler
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(template, _source)
      @calls << template.identifier

      "@output_buffer.safe_append='fallback:#{template.format}'.freeze;@output_buffer"
    end
  end

  before do
    @previous = [
      ReActionView.config.debug_mode,
      ReActionView.config.slots,
      ReActionView.config.external_template_mode,
      ReActionView.config.validation_mode
    ]

    ReActionView.config.debug_mode = false
    ReActionView.config.slots = false
  end

  after do
    ReActionView.config.debug_mode, ReActionView.config.slots, ReActionView.config.external_template_mode, ReActionView.config.validation_mode = @previous
  end

  def build(source, identifier, format: :html, handler: ReActionView::Template::Handlers::Slim.new)
    ActionView::Template.new(source, identifier, handler, virtual_path: "users/show", format: format, locals: [])
  end

  def compile(source, identifier = VIEW, format: :html, handler: ReActionView::Template::Handlers::Slim.new)
    template = build(source, identifier, format: format, handler: handler)

    Rails.stub(:root, Pathname.new(RAILS_ROOT)) do
      handler.call(template, source)
    end
  end

  def render(compiled, **assigns)
    view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([]), {}, nil)
    view.instance_variable_set(:@output_buffer, ActionView::OutputBuffer.new)
    assigns.each { |name, value| view.instance_variable_set(:"@#{name}", value) }

    view.instance_eval(compiled).to_s
  end

  test "renders a .html.slim template the way Slim does" do
    html = render(compile(VIEW_SOURCE), name: "Marco", message: "Hi <there>", admin: true)

    assert_equal(
      %(<div class="card"><h1>Hello Marco</h1><p class="lead" title="x">Hi &lt;there&gt;</p><span class="badge">Admin</span></div>),
      html
    )
  end

  test "escapes `=` and leaves `==` raw" do
    html = render(compile("p = @html\np == @html\n"), html: "<b>x</b>")

    assert_equal "<p>&lt;b&gt;x&lt;/b&gt;</p><p><b>x</b></p>", html
  end

  test "a Ruby error is reported on the Slim line it came from" do
    compiled = compile("div\n  p Hi\n\n  p\n    | text\n  = @missing.boom\n")

    error = assert_raises(NoMethodError) do
      view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([]), {}, nil)
      view.instance_variable_set(:@output_buffer, ActionView::OutputBuffer.new)
      view.instance_eval(compiled, VIEW, 1)
    end

    line = error.backtrace_locations.find { |location| location.path == VIEW }&.lineno

    assert_equal 6, line
  end

  test "debug mode marks Slim templates with their Slim file and lines" do
    ReActionView.config.debug_mode = true

    compiled = compile(VIEW_SOURCE)

    assert_includes compiled, %(data-herb-debug-file-full-path="/app/app/views/users/show.html.slim")
    assert_includes compiled, %(data-herb-debug-line="3")
  end

  test "a Slim layout gets the dev tools in its head in debug mode" do
    ReActionView.config.debug_mode = true
    ReActionView.config.validation_mode = :overlay

    compiled = compile(LAYOUT_SOURCE, LAYOUT)
    head = compiled[%r{<head>.*</head>}m]

    refute_nil head
    assert_includes head, "herb-debug-mode"
    assert_includes head, "reactionview-dev-tools"
    assert_includes head, "data-herb-dismiss-hint"
  end

  test "a Slim layout gets nothing in its head when debug mode is off" do
    compiled = compile(LAYOUT_SOURCE, LAYOUT)

    refute_includes compiled, "herb-debug-mode"
    refute_includes compiled, "reactionview-dev-tools"
  end

  test "validators report on Slim templates" do
    ReActionView.config.validation_mode = :raise

    error = assert_raises(::Herb::Engine::CompilationError) do
      compile("p\n  h2 I am invalid\n")
    end

    assert_includes error.message, "show.html.slim:2:"
  end

  test "registered visitors run on Slim templates" do
    visitor_class = Class.new(::Herb::Visitor) do
      def visit_html_text_node(node)
        node.content.replace(node.content.upcase)
        super
      end
    end

    registration = ::Herb::Engine.register_visitor(visitor_class)

    begin
      assert_equal "<p>HELLO</p>", render(compile("p hello\n"))
    ensure
      ::Herb::Engine.unregister_visitor(registration)
    end
  end

  test "without a fallback every format compiles with Herb" do
    html = render(compile("| Hello \#{@name}\n", "/app/app/views/mailer/welcome.text.slim", format: :text), name: "Marco")

    assert_equal "Hello Marco", html
  end

  test "formats other than html and slots keep the handler .slim had before" do
    fallback = FallbackHandler.new
    handler = ReActionView::Template::Handlers::Slim.new(fallback: fallback)

    html = render(compile("| Hello\n", "/app/app/views/mailer/welcome.text.slim", format: :text, handler: handler))

    assert_equal "fallback:text", html
    assert_equal ["/app/app/views/mailer/welcome.text.slim"], fallback.calls
  end

  test "application templates compile with Herb even with a fallback" do
    fallback = FallbackHandler.new
    handler = ReActionView::Template::Handlers::Slim.new(fallback: fallback)

    assert_equal "<p>Hi</p>", render(compile("p Hi\n", handler: handler))
    assert_empty fallback.calls
  end

  test "gem templates in :skip mode go to the fallback" do
    ReActionView.config.external_template_mode = :skip

    fallback = FallbackHandler.new
    handler = ReActionView::Template::Handlers::Slim.new(fallback: fallback)

    assert_equal "fallback:html", render(compile("p Hi\n", EXTERNAL, handler: handler))
  end

  test "gem templates in :fallback mode fall back when Herb rejects them" do
    ReActionView.config.external_template_mode = :fallback

    fallback = FallbackHandler.new
    handler = ReActionView::Template::Handlers::Slim.new(fallback: fallback)

    assert_equal "<p>Hi</p>", render(compile("p Hi\n", EXTERNAL, handler: handler))
    assert_equal "fallback:html", render(compile("p\n  h2 I am invalid\n", EXTERNAL, handler: handler))
  end

  test "gem templates compile with Herb when there is nothing to fall back to" do
    ReActionView.config.external_template_mode = :skip

    assert_equal "<p>Hi</p>", render(compile("p Hi\n", EXTERNAL))
  end

  test "an ERB template through the Herb handler compiles as it always has" do
    source = "<p><%= @name %></p>"
    template = ActionView::Template.new(source, "/app/app/views/users/show.html.erb", ReActionView::Template::Handlers::Herb, virtual_path: "users/show", format: :html, locals: [])

    compiled = Rails.stub(:root, Pathname.new(RAILS_ROOT)) { ReActionView::Template::Handlers::Herb.call(template, source) }

    assert_equal "<p>Marco</p>", render(compiled, name: "Marco")
  end

  test "an inline template compiles as Slim when the handler says so" do
    template = build("p Hi\n", "inline template")

    compiled = Rails.stub(:root, Pathname.new(RAILS_ROOT)) { ReActionView::Template::Handlers::Slim.new.call(template, "p Hi\n") }

    assert_equal "<p>Hi</p>", render(compiled)
  end
end
