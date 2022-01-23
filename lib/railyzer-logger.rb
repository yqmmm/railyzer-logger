module RailyzerLogger
  # Modified from Rails:BacktraceCleaner
  class BackTraceCleaner < ActiveSupport::BacktraceCleaner
    APP_DIRS_PATTERN = /^\/?(app|config|lib|test|\(\w*\))/
    ABOSOLUTE_DIR_PATTERN = /^\/.*/
    RENDER_TEMPLATE_PATTERN = /:in `.*_\w+_{2,3}\d+_\d+'/
    EMPTY_STRING = ""
    SLASH = "/"
    DOT_SLASH = "./"

    def initialize
      super
      @root = ENV['RAILYZER_LOGGER_ROOT'] ? ENV['RAILYZER_LOGGER_ROOT'].dup : "#{Rails.root}/"
      if @root[-1] != SLASH
        @root << SLASH
      end
      add_filter { |line| line.sub(@root, EMPTY_STRING) }
      add_filter { |line| line.sub(RENDER_TEMPLATE_PATTERN, EMPTY_STRING) }
      add_filter { |line| line.sub(DOT_SLASH, SLASH) } # for tests
      # add_silencer { |line| !APP_DIRS_PATTERN.match?(line) }

      # If a line begins with "/", it is not filterd by @root and is not in root directory.
      # So, we need to silence it. It looks stupid, but we have to do this because
      # ActiveSupport::BacktraceCleaner apply filters first and then silencers.
      add_silencer { |line| ABOSOLUTE_DIR_PATTERN.match?(line) }
    end
  end

  module SqlSource
    class << self
      attr_accessor :current_api
      attr_accessor :dest

      # Use this or queries from concurrent requests will be messed up
      def store
        defined?(RequestStore) ? RequestStore.store : Thread.current
      end

      def register_sql(sql)
        if Rails.env.test?
          @dest.puts sql
        else
          store[:sql_log] ||= []
          store[:sql_log] << sql
        end
      end

      def finish_api(event) sql_log = store[:sql_log] || []
        store[:sql_log] = nil

        header = "#{event.payload[:method]} #{event.payload[:path]}"
        sql_log.unshift("+#{header}")
        sql_log << "-#{header}"
        @dest.puts sql_log.join("\n")
        @dest.flush
      end
    end
  end

  # From lograge
  def remove_existing_log_subscriptions
    require 'action_controller/log_subscriber'
    ActiveSupport::LogSubscriber.log_subscribers.each do |subscriber|
      case subscriber
      when ActionView::LogSubscriber
        unsubscribe(:action_view, subscriber)
      when ActionController::LogSubscriber
        unsubscribe(:action_controller, subscriber)
      end
    end
  end

  def unsubscribe(component, subscriber)
    events = subscriber.public_methods(false).reject { |method| method.to_s == 'call' }
    events.each do |event|
      ActiveSupport::Notifications.notifier.listeners_for("#{event}.#{component}").each do |listener|
        if listener.instance_variable_get('@delegate') == subscriber
          ActiveSupport::Notifications.unsubscribe listener
        end
      end
    end
  end

  SqlSource.dest = File.new("railyzer-#{Time.now.strftime("%m-%d_%H-%M-%S")}.logs", "w")
  cleaner = BackTraceCleaner.new

  ActiveSupport::Notifications.subscribe "sql.active_record" do |*args|
    event = ActiveSupport::Notifications::Event.new *args

    cleaned_trace = cleaner.clean(caller).join(", ")

    unless event.payload[:cached] or event.payload[:name] == 'SCHEMA'
      SqlSource.register_sql "\#" + 
                            if event.payload[:cached] then "(cached)" else "" end + 
                            "#{cleaned_trace}"
      SqlSource.register_sql event.payload[:sql]
    end
  end

  # There is also a `start_processing.action_controller` event which is fired when an action
  # begins to be handled
  ActiveSupport::Notifications.subscribe "process_action.action_controller" do |*args|
    event = ActiveSupport::Notifications::Event.new *args

    SqlSource.finish_api event
  end
end

