# frozen_string_literal: true

require 'webrick'
require 'stringio'
require 'rack/content_length'

module Rack
  module Handler
    class WEBrick < ::WEBrick::HTTPServlet::AbstractServlet
      # This extension allows for applications to
      # configure chunking and perform it on their own, instead of doing it
      # via webrick.
      class RackWebrickResponse < ::WEBrick::HTTPResponse
        attr_accessor :rack

        def setup_header
          app_chunking = rack && @header['transfer-encoding'] == 'chunked'
          @chunked = app_chunking if app_chunking
          super
          @chunked = false if app_chunking
        end

        # If we have a Rack body response that is a hijack response or iterable,
        # do not let the HTTPResponse read it. Instead, let the Rack 
        # response wrapper write itself to the socket, bypassing WEBrick.
        def send_body(socket) # :nodoc:
          if @body.respond_to?(:is_rack_response?) && body.is_rack_response?
            @body.write_to_socket(socket)
          else
            super
          end
        end
      end

      class HijackingBody < Struct.new(:handling_proc)
        def is_rack_response?; true; end
        def write_to_socket(socket)
          handling_proc.call(socket)
        end
      end

      class IterableBody < Struct.new(:wrapped_rack_body)
        def is_rack_response?; true; end
        def write_to_socket(socket)
          wrapped_rack_body.each do |chunk|
            socket.write(chunk)
          end
        end
      end

      def self.run(app, options = {})
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : nil

        options[:BindAddress] = options.delete(:Host) || default_host
        options[:Port] ||= 8080
        if options[:SSLEnable]
          require 'webrick/https'
        end

        @server = ::WEBrick::HTTPServer.new(options)
        @server.mount "/", Rack::Handler::WEBrick, app
        yield @server  if block_given?
        @server.start
      end

      def self.valid_options
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : '0.0.0.0'

        {
          "Host=HOST" => "Hostname to listen on (default: #{default_host})",
          "Port=PORT" => "Port to listen on (default: 8080)",
        }
      end

      def self.shutdown
        @server.shutdown
        @server = nil
      end

      def initialize(server, app)
        super server
        @app = app
      end

      def create_request_and_response(with_webrick_config)
        req = ::WEBrick::HTTPRequest.new(with_webrick_config)
        res = RackWebrickResponse.new(with_webrick_config)
        [req, res]
      end

      def service(req, res)
        env = req.meta_vars
        env.delete_if { |k, v| v.nil? }

        rack_input = StringIO.new(req.body.to_s)
        rack_input.set_encoding(Encoding::BINARY)

        env.update(
          RACK_VERSION      => Rack::VERSION,
          RACK_INPUT        => rack_input,
          RACK_ERRORS       => $stderr,
          RACK_MULTITHREAD  => true,
          RACK_MULTIPROCESS => false,
          RACK_RUNONCE      => false,
          RACK_URL_SCHEME   => ["yes", "on", "1"].include?(env[HTTPS]) ? "https" : "http",
          RACK_IS_HIJACK    => true,
          RACK_HIJACK       => lambda { raise NotImplementedError, "only partial hijack is supported."},
          RACK_HIJACK_IO    => nil
        )

        env[HTTP_VERSION] ||= env[SERVER_PROTOCOL]
        env[QUERY_STRING] ||= ""
        unless env[PATH_INFO] == ""
          path, n = req.request_uri.path, env[SCRIPT_NAME].length
          env[PATH_INFO] = path[n, path.length - n]
        end
        env[REQUEST_PATH] ||= [env[SCRIPT_NAME], env[PATH_INFO]].join

        status, headers, body = @app.call(env)
        begin
          res.status = status.to_i
          io_lambda = nil
          headers.each { |k, vs|
            if k == RACK_HIJACK
              io_lambda = vs
            elsif k.downcase == "set-cookie"
              res.cookies.concat vs.split("\n")
            else
              # Since WEBrick won't accept repeated headers,
              # merge the values per RFC 1945 section 4.2.
              res[k] = vs.split("\n").join(", ")
            end
          }

          io_lambda = headers["rack.hijack"]
          if io_lambda
            res.body = HijackingBody.new(io_lambda)
          elsif body.respond_to?(:to_path)
            res.body = ::File.open(body.to_path, 'rb')
          else
            res.body = IterableBody.new(body)
          end
        ensure
          body.close  if body.respond_to? :close
        end
      end
    end
  end
end
