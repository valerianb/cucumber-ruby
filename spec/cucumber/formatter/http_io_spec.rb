# frozen_string_literal: true

require 'stringio'
require 'webrick'
require 'webrick/https'
require 'spec_helper'
require 'cucumber/formatter/io'

module Cucumber
  module Formatter
    describe HTTPIO do
      include Io

      # rubocop:disable Metrics/MethodLength
      def start_server
        uri = URI('http://localhost')
        @received_body_io = StringIO.new

        rd, wt = IO.pipe
        webrick_options = {
          Port: 0,
          Logger: WEBrick::Log.new(File.open(File::NULL, 'w')),
          AccessLog: [],
          StartCallback: proc do
                           wt.write(1) # write "1", signal a server start message
                           wt.close
                         end
        }
        if uri.scheme == 'https'
          webrick_options[:SSLEnable] = true
          # Set up a self-signed cert
          webrick_options[:SSLCertName] = [%w[CN localhost]]
        end

        @server = WEBrick::HTTPServer.new(webrick_options)
        @server.mount_proc '/' do |req, _res|
          IO.copy_stream(req.body_reader, @received_body_io)
        end

        @server.mount_proc '/404' do |_req, res|
          res.status = 404
        end

        @server.mount_proc '/redirect' do |_req, res|
          res.set_redirect(
            WEBrick::HTTPStatus::TemporaryRedirect,
            '/'
          )
        end

        @server.mount_proc '/loop_redirect' do |_req, res|
          res.set_redirect(
            WEBrick::HTTPStatus::TemporaryRedirect,
            '/loop_redirect'
          )
        end

        Thread.new do
          @server.start
        end
        rd.read(1) # read a byte for the server start signal
        rd.close

        "http://localhost:#{@server.config[:Port]}"
      end
      # rubocop:enable Metrics/MethodLength

      context 'created by Io#ensure_io' do
        it 'creates an IO that PUTs with HTTP' do
          url = start_server
          sent_body = 'X' * 10_000_000 # 10Mb

          io = ensure_io("#{url}/?http-method=POST")
          io.write(sent_body)
          io.flush
          io.close
          @received_body_io.rewind
          received_body = @received_body_io.read
          expect(received_body).to eq(sent_body)
        end

        it 'streams HTTP body to server' do
          url = start_server
          sent_body = 'X' * 10_000_000

          io = ensure_io("#{url}/?http-method=POST")
          io.write(sent_body)
          io.flush
          sleep 0.2 # ugh
          # Not calling io.close
          @received_body_io.rewind
          received_body = @received_body_io.read
          expect(received_body.length).to be > 0
        end

        it 'notifies user if the server responds with error' do
          url = start_server
          io = ensure_io("#{url}/404?http-method=POST")
          expect { io.close }.to(raise_error("request to #{url}/404?http-method=POST failed with status 404"))
        end

        it 'notifies user if the server is unreachable' do
          io = ensure_io('http://localhost:9987')
          expect { io.close }.to(raise_error(/Failed to open TCP connection to localhost:9987/))
        end

        it 'follows redirects' do
          url = start_server
          sent_body = 'X' * 10_000_000

          io = ensure_io("#{url}/redirect?http-method=POST")
          io.write(sent_body)
          io.flush
          io.close
          @received_body_io.rewind
          received_body = @received_body_io.read
          expect(received_body).to eq(sent_body)
        end

        it 'raises an error when maximum redirection is reached' do
          url = start_server
          io = ensure_io("#{url}/loop_redirect?http-method=POST")
          expect { io.close }.to(raise_error("request to #{url}/loop_redirect failed (too many redirections)"))
        end
      end

      context 'created with constructor (because we need to relax SSL verification during testing)' do
        it 'PUTs with HTTPS' do
          url = start_server
          sent_body = 'X' * 10_000_000 # 10Mb

          io = HTTPIO.open("#{url}/?http-method=POST", OpenSSL::SSL::VERIFY_NONE)
          io.write(sent_body)
          io.flush
          io.close
          @received_body_io.rewind
          received_body = @received_body_io.read
          expect(received_body).to eq(sent_body)
        end
      end

      it 'default method is PUT' do
        uri, method, = HTTPIO.build_uri_method_headers('http://localhost:9987?foo=bar')
        expect(method).to eq('PUT')
        expect(uri.to_s).to eq('http://localhost:9987?foo=bar')
      end

      it 'sets HTTP method when http-method is set' do
        uri, method, = HTTPIO.build_uri_method_headers('http://localhost:9987?http-method=GET&foo=bar')
        expect(method).to eq('GET')
        expect(uri.to_s).to eq('http://localhost:9987?foo=bar')
      end

      it 'sets Content-Type header when http-content-type query parameter set' do
        uri, _method, headers = HTTPIO.build_uri_method_headers('http://localhost:9987?http-content-type=text/plain&foo=bar')
        expect(headers['content-type']).to eq('text/plain')
        expect(uri.to_s).to eq('http://localhost:9987?foo=bar')
      end

      after do
        @server&.shutdown
      end
    end
  end
end