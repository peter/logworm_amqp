require 'rack/request'

module Logworm
  class Rack

    def initialize(app, options = {})
      @app = app
      @log_requests = (options[:donot_log_requests].nil? or options[:donot_log_requests] != true)
      @log_listener = options[:log_listener]
      @log_headers  = (options[:log_headers] and options[:log_headers] == true)
      @log_apache   = (options[:log_apache] and options[:log_apache] == true)
      @log_envs     = options[:log_environments] || ["production"]
      @log_envs << "development" if (options[:log_in_development] and options[:log_in_development] == true) # backwards compatibility
      Logger.use_default_db
      @timeout = (ENV['RACK_ENV'] == 'production' ? 1 : 5) 
    end

    def call(env)
      return @app.call(env) unless @log_envs.include?(ENV['RACK_ENV'])

      Logger.start_cycle
      begin
        startTime = Time.now 
        status, response_headers, body = @app.call(env) 
        appTime = (Time.now - startTime) 
      ensure
        log_request(env, status, response_headers, appTime)
        return [status, response_headers, body] 
      end
    end
    
    private 
    def call_log_listener(options = {})
      return unless @log_listener
      @log_listener.call(options)
    end
    
    def log_request(env, status, response_headers, appTime)
      method       = env['REQUEST_METHOD']
      path         = env['PATH_INFO'] || env['REQUEST_PATH'] || "/"
      ip           = env['REMOTE_ADDR']
      http_headers = env.reject {|k,v| !(k.to_s =~ /^HTTP/) }
      queue_size   = env['HTTP_X_HEROKU_QUEUE_DEPTH'].nil? ? -1 : env['HTTP_X_HEROKU_QUEUE_DEPTH'].to_i

      entry = { :summary         => "#{method} #{path} - #{status} #{appTime}", 
                :request_method  => method,
                :request_path    => path, 
                :request_ip      => ip,
                :input           => ::Rack::Request.new(env).params,
                :response_status => status, 
                :profiling       => appTime,
                :queue_size      => queue_size}
      entry[:request_headers]  = http_headers if @log_headers
      entry[:response_headers] = response_headers if @log_headers
      entry[:apache_log]       = Logger.apache_log(ip, method, path, env, status, response_headers) if @log_apache
      Logger.log(:web_log, entry) if @log_requests

      begin 
        Timeout::timeout(@timeout) { 
          count, elapsed_time = Logger.flush
          call_log_listener(:result => :success, :count => count, :elapsed_time => elapsed_time)
        } 
      rescue Exception => e 
        # Ignore --nothing we can do. The list of logs may (and most likely will) be preserved for the next request
        $stderr.puts("logworm call failed: #{e}")
        call_log_listener(:result => :failure, :exception => e)
      end
    end

  end
end
