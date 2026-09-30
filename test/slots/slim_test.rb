# frozen_string_literal: true

require_relative "../test_helper"

require "action_controller"
require "rack/mock"
require "tmpdir"
require "herb/dev"

class ReActionView::Slots::SlimTest < Minitest::Spec
  RAILS_ROOT = "/app"
  VIEW = "/app/app/views/users/show.html.slim"

  SOURCE = <<~SLIM
    div.card
      h1 Hello
      p.lead title="x" = @name
      - if @admin
        span Admin
  SLIM

  class View
    def initialize(**assigns)
      assigns.each { |name, value| instance_variable_set(:"@#{name}", value) }
    end
  end

  class FakeServer
    attr_reader :messages

    def initialize
      @messages = []
    end

    def broadcast(message, to: :all) # rubocop:disable Lint/UnusedMethodArgument
      @messages << message
    end
  end

  class Executor
    def wrap
      yield
    end
  end

  class GreetingsController < ActionController::Base
    prepend ReActionView::Slots::Rendering

    def self.controller_path = "greetings"

    def show
      @name = "Marco"

      respond_to do |format|
        format.slots { render :show }
        format.html { render :show }
      end
    end
  end

  before do
    @previous = [ReActionView.config.slots, ReActionView.config.debug_mode, ReActionView.config.intercept_slim]

    ReActionView.config.slots = :client
    ReActionView.config.debug_mode = false
  end

  after do
    ReActionView.config.slots, ReActionView.config.debug_mode, ReActionView.config.intercept_slim = @previous
  end

  def schema(source, path = VIEW)
    Rails.stub(:root, Pathname.new(RAILS_ROOT)) do
      ReActionView::Template::Handlers::Herb.compile_for_schema(source, path)
    end
  end

  def compile(source, format:)
    template = ActionView::Template.new(source, VIEW, ReActionView::Template::Handlers::Slim.new, virtual_path: "users/show", format: format, locals: [])

    Rails.stub(:root, Pathname.new(RAILS_ROOT)) do
      template.handler.call(template, source)
    end
  end

  def html(source, view = View.new)
    view.instance_variable_set(:@output_buffer, ActionView::OutputBuffer.new)

    view.instance_eval(compile(source, format: :html)).to_s
  end

  def values(source, view = View.new)
    view.instance_eval(compile(source, format: :slots))
  end

  it "compiles a Slim template's schema" do
    result = schema(SOURCE)

    assert_equal :client, result.mode
    assert_equal([:child, :conditional], result.slot_entries.map { |entry| entry[:type] })
    assert_equal(
      %(<div class="card"><h1>Hello</h1><p class="lead" title="x" data-herb-slot="0:child"></p><!--herb-slot:1:conditional--><!--/herb-slot:1--></div>),
      result.static_markup
    )
    assert_equal({ "1:0" => "<!--herb-branch:1:0--><span>Admin</span>" }, result.statics)
    assert_empty result.diagnostics
  end

  it "renders the Slim page with a region the schema's version names" do
    page = html(SOURCE, View.new(name: "Marco", admin: true))

    assert_includes page, "<!--herb-region:app/views/users/show.html.slim:#{schema(SOURCE).version}:0-->"
    assert_includes page, %(<p class="lead" title="x" data-herb-slot="0:child">Marco</p>)
  end

  it "answers a values request for a Slim template with the page's version" do
    payload = values(SOURCE, View.new(name: "Marco", admin: false))

    assert_equal "app/views/users/show.html.slim", payload[:template]
    assert_equal schema(SOURCE).version, payload[:version]
    assert_equal "Marco", payload[:slots][0]
  end

  it "reads a Slim herb:slots directive" do
    assert_equal :server, schema("/ herb:slots server\np = @name\n").mode
    assert_equal :server, ReActionView.config.slot_mode_for("/ herb:slots server\np = @name\n", VIEW)
    assert_equal :client, ReActionView.config.slot_mode_for("/ herb:slots server\np = @name\n", "/app/app/views/users/show.html.erb")

    ReActionView.config.slots = false

    assert_equal :client, schema("/ herb:slots client\np = @name\n").mode
    assert_nil schema("p = @name\n").mode
  end

  describe "the dev server" do
    def pipeline(server)
      compiler = ReActionView::Slots::DevCompiler.new
      application = Struct.new(:executor).new(Executor.new)

      ::Herb::Dev::Pipeline.new(
        server: server,
        compiler: -> { ->(source, path) { Rails.stub(:application, application) { Rails.stub(:root, Pathname.new(RAILS_ROOT)) { compiler.call(source, path) } } } }
      )
    end

    def edit(subject, previous, current)
      subject.handle_event(
        ::Herb::Dev::Watcher::Event.new(
          kind: :changed,
          path: VIEW,
          relative_path: "app/views/users/show.html.slim",
          previous: previous,
          current: current
        )
      )
    end

    before do
      @project_path = ReActionView.config.project_path if ReActionView.config.instance_variable_get(:@project_path)
      ReActionView.config.project_path = RAILS_ROOT
    end

    after do
      ReActionView.config.project_path = @project_path
    end

    it "patches a Slim text edit in place from the new static markup" do
      server = FakeServer.new

      edit(pipeline(server), SOURCE, SOURCE.sub("Hello", "Welcome"))

      schema_message = server.messages.find { |message| message[:type] == "schema" }
      invalidate = server.messages.find { |message| message[:type] == "invalidate" }

      assert_equal "static", invalidate[:scope]
      assert_equal schema_message[:version][:to], invalidate[:version]
      assert_equal "client", schema_message[:mode]
      assert_includes schema_message[:static_markup], "<h1>Welcome</h1>"
      assert_empty schema_message[:diagnostics]
    end

    it "patches a Slim attribute edit in place" do
      server = FakeServer.new

      edit(pipeline(server), SOURCE, SOURCE.sub("div.card", "div.card.wide"))

      invalidate = server.messages.find { |message| message[:type] == "invalidate" }
      schema_message = server.messages.find { |message| message[:type] == "schema" }

      assert_equal "static", invalidate[:scope]
      assert_includes schema_message[:static_markup], %(<div class="card wide">)
    end

    it "fetches a structural Slim edit and remaps the slots that moved" do
      server = FakeServer.new
      subject = pipeline(server)
      inserted = SOURCE.sub("  h1 Hello\n", "  h1 Hello\n  h2 Subtitle\n")

      edit(subject, SOURCE, SOURCE.sub("Hello", "Hi"))
      edit(subject, SOURCE.sub("Hello", "Hi"), inserted.sub("Hello", "Hi"))

      schema_message = server.messages.select { |message| message[:type] == "schema" }.last
      invalidate = server.messages.select { |message| message[:type] == "invalidate" }.last

      assert_equal "fetch", invalidate[:scope]
      assert_equal({ "slots" => { "0" => 0, "1" => 1 } }, schema_message[:remap])
      assert_includes schema_message[:static_markup], "<h2>Subtitle</h2>"
    end

    it "reports a Slim parse error at its Slim line" do
      server = FakeServer.new

      edit(pipeline(server), SOURCE, "div\n  p Hi\na(href=\"x\"\n")

      error = server.messages.find { |message| message[:type] == "error" }

      assert_equal 3, error[:errors].first[:line]
    end
  end

  describe "a controller rendering a .html.slim view" do
    before do
      @previous_handler = ReActionView::Railtie.registered_slim_handler

      ActionView::Template.register_template_handler :slim, ReActionView::Template::Handlers::Slim.new
      Mime::Type.register(ReActionView::Slots::MIME_TYPE, ReActionView::Slots::FORMAT) unless Mime[ReActionView::Slots::FORMAT]
    end

    after do
      if @previous_handler
        ActionView::Template.register_template_handler :slim, @previous_handler
      else
        ActionView::Template.unregister_template_handler :slim
      end
    end

    around do |work|
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "greetings"))
        File.write(File.join(root, "greetings", "show.html.slim"), "/ herb:slots client\np Hello, \#{@name}\n")

        GreetingsController.view_paths = [
          ReActionView::Slots::Resolver.new(root),
          ActionView::FileSystemResolver.new(root)
        ]

        work.call
      end
    end

    def dispatch(accept, headers: {})
      env = Rack::MockRequest.env_for("/greetings", method: "GET")
      env["HTTP_ACCEPT"] = accept
      headers.each { |name, value| env["HTTP_#{name.upcase.tr("-", "_")}"] = value }

      status, _response_headers, body = GreetingsController.action(:show).call(env)
      payload = +""
      body.each { |chunk| payload << chunk }

      [status, payload]
    end

    it "renders the page with its slot markers" do
      status, body = dispatch("text/html")

      assert_equal 200, status
      assert_includes body, "herb-region:"
      assert_includes body, "<p>Hello, <!--herb-slot:0-->Marco<!--/herb-slot:0--></p>"
    end

    it "answers a values request with the schema envelope" do
      status, payload = dispatch(ReActionView::Slots::MIME_TYPE, headers: { "Herb-Schema" => "1" })
      json = JSON.parse(payload)

      assert_equal 200, status
      assert_equal "Marco", json["slots"]["0"]
      assert_equal json["version"], json["schema"]["version"]
      assert_includes json["schema"]["static_markup"], "herb-slot:0"
    end
  end

  it "registers the Slim handler over the one .slim had, and keeps it as the fallback" do
    previous = ReActionView::Railtie.registered_slim_handler
    original = ->(_template, _source) { "" }

    ActionView::Template.register_template_handler :slim, original
    ReActionView::Railtie.register_slim_handler
    ReActionView::Railtie.register_slim_handler

    handler = ReActionView::Railtie.registered_slim_handler

    assert_kind_of ReActionView::Template::Handlers::Slim, handler
    assert_same original, handler.fallback
  ensure
    if previous
      ActionView::Template.register_template_handler :slim, previous
    else
      ActionView::Template.unregister_template_handler :slim
    end
  end
end
