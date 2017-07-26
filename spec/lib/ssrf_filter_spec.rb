require 'spec_helper'
require 'timeout'
require 'webrick/https'

describe SsrfFilter do
  before :all do
    SsrfFilter.make_all_class_methods_public!
  end

  let(:public_ipv4) { IPAddr.new('172.217.6.78') }
  let(:private_ipv4) { IPAddr.new('127.0.0.1') }
  let(:public_ipv6) { IPAddr.new('2606:2800:220:1:248:1893:25c8:1946') }
  let(:private_ipv6) { IPAddr.new('::1') }

  context 'unsafe_ip_address?' do
    it 'should return true if the ipaddr has a mask' do
      expect(SsrfFilter.unsafe_ip_address?(IPAddr.new("#{public_ipv4}/16"))).to be(true)
    end

    it 'should return true for private ipv4 addresses' do
      expect(SsrfFilter.unsafe_ip_address?(private_ipv4)).to be(true)
    end

    it 'should return false for public ipv4 addresses' do
      expect(SsrfFilter.unsafe_ip_address?(public_ipv4)).to be(false)
    end

    it 'should return true for private ipv6 addresses' do
      expect(SsrfFilter.unsafe_ip_address?(private_ipv6)).to be(true)
    end

    it 'should return true for mapped/compat ipv4 addresses' do
      SsrfFilter::IPV4_BLACKLIST.each do |addr|
        %i[ipv4_compat ipv4_mapped].each do |method|
          first = addr.to_range.first.send(method).mask(128)
          expect(SsrfFilter.unsafe_ip_address?(first)).to be(true)

          last = addr.to_range.last.send(method).mask(128)
          expect(SsrfFilter.unsafe_ip_address?(last)).to be(true)
        end
      end
    end

    it 'should return false for public ipv6 addresses' do
      expect(SsrfFilter.unsafe_ip_address?(public_ipv6)).to be(false)
    end

    it 'should return true for unknown ip families' do
      allow(public_ipv4).to receive(:ipv4?).and_return(false)
      allow(public_ipv4).to receive(:ipv6?).and_return(false)
      expect(SsrfFilter.unsafe_ip_address?(public_ipv4)).to be(true)
    end
  end

  context 'prefixlen_from_ipaddr' do
    it 'should return the prefix length' do
      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('0.0.0.0/8'))).to eq(8)
      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('198.18.0.0/15'))).to eq(15)
      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('255.255.255.255'))).to eq(32)

      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('::1'))).to eq(128)
      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('64:ff9b::/96'))).to eq(96)
      expect(SsrfFilter.prefixlen_from_ipaddr(IPAddr.new('fc00::/7'))).to eq(7)
    end
  end

  context 'ipaddr_has_mask?' do
    it 'should return true if the ipaddr has a mask' do
      expect(SsrfFilter.ipaddr_has_mask?(IPAddr.new("#{private_ipv4}/8"))).to be(true)
    end

    it 'should return false if the ipaddr has no mask' do
      expect(SsrfFilter.ipaddr_has_mask?(private_ipv4)).to be(false)
      expect(SsrfFilter.ipaddr_has_mask?(IPAddr.new("#{private_ipv4}/32"))).to be(false)
      expect(SsrfFilter.ipaddr_has_mask?(IPAddr.new("#{private_ipv6}/128"))).to be(false)
    end
  end

  context 'fetch_once' do
    it 'should set the host header' do
      stub_request(:post, "https://#{public_ipv4}").with(headers: {host: 'www.example.com:443'}).to_return(
        status: 200, body: 'response body')
      response = SsrfFilter.fetch_once(URI('https://www.example.com'), public_ipv4.to_s, :post, {})
      expect(response.code).to eq('200')
      expect(response.body).to eq('response body')
    end

    it 'should pass headers, params, and blocks' do
      stub_request(:get, "https://#{public_ipv4}/?key=value").with(headers:
        {host: 'www.example.com:443', header: 'value', header2: 'value2'}).to_return(status: 200, body: 'response body')
      options = {
        headers: {'header' => 'value'},
        params: {'key' => 'value'}
      }
      uri = URI('https://www.example.com/?key=value')
      response = SsrfFilter.fetch_once(uri, public_ipv4.to_s, :get, options) do |req|
        req['header2'] = 'value2'
      end
      expect(response.code).to eq('200')
      expect(response.body).to eq('response body')
    end

    it 'should merge params' do
      stub_request(:get, "https://#{public_ipv4}/?key=value&key2=value2").with(
        headers: {host: 'www.example.com:443'}).to_return(status: 200, body: 'response body')
      uri = URI('https://www.example.com/?key=value')
      response = SsrfFilter.fetch_once(uri, public_ipv4.to_s, :get, params: {'key2' => 'value2'})
      expect(response.code).to eq('200')
      expect(response.body).to eq('response body')
    end

    it 'should not use tls for http urls' do
      expect(::Net::HTTP).to receive(:start).with(public_ipv4.to_s, 80, use_ssl: false)
      SsrfFilter.fetch_once(URI('http://www.example.com'), public_ipv4.to_s, :get, {})
    end

    it 'should use tls for https urls' do
      expect(::Net::HTTP).to receive(:start).with(public_ipv4.to_s, 443, use_ssl: true)
      SsrfFilter.fetch_once(URI('https://www.example.com'), public_ipv4.to_s, :get, {})
    end
  end

  context 'with_forced_hostname' do
    it 'should set the value for the block and clear it afterwards' do
      expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to be_nil
      SsrfFilter.with_forced_hostname('test') do
        expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to eq('test')
      end
      expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to be_nil
    end

    it 'should clear the value even if an exception is raised' do
      expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to be_nil
      expect do
        SsrfFilter.with_forced_hostname('test') do
          expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to eq('test')
          raise StandardError
        end
      end.to raise_error(StandardError)
      expect(Thread.current[SsrfFilter::FIBER_LOCAL_KEY]).to be_nil
    end
  end

  context 'patch_ssl_socket' do
    before :each do
      if SsrfFilter.instance_variable_defined?(:@patched_ssl_socket)
        SsrfFilter.remove_instance_variable(:@patched_ssl_socket)
      end
    end

    it 'should only patch once' do
      expect(::OpenSSL::SSL::SSLSocket).to receive(:class_eval)
      SsrfFilter.patch_ssl_socket!
      SsrfFilter.patch_ssl_socket!
    end

    context 'integration tests' do
      # To test the SSLSocket patching logic (and hit 100% code coverage), we need to make a real connection to a
      # TLS-enabled server. To do this we create a private key and certificate, spin up a web server in
      # a thread (serving traffic on localhost), and make a request to the server. This requires several things:
      # 1) creating a custom trust store with our certificate and using that for validation
      # 2) allowing (non-mocked) network connections
      # 3) stubbing out the IPV4_BLACKLIST to allow connections to localhost

      allow_net_connections_for_context(self)

      def make_keypair(subject)
        private_key = OpenSSL::PKey::RSA.new(2048)
        public_key = private_key.public_key
        subject = OpenSSL::X509::Name.parse(subject)

        certificate = OpenSSL::X509::Certificate.new
        certificate.subject = subject
        certificate.issuer = subject
        certificate.not_before = Time.now
        certificate.not_after = Time.now + 60 * 60 * 24
        certificate.public_key = public_key
        certificate.serial = 0x0
        certificate.version = 2

        certificate.sign(private_key, OpenSSL::Digest::SHA256.new)

        [private_key, certificate]
      end

      def make_web_server(port, private_key, certificate, opts = {}, &block)
        server = WEBrick::HTTPServer.new({
          Port: port,
          SSLEnable: true,
          SSLCertificate: certificate,
          SSLPrivateKey: private_key,
          StartCallback: block
        }.merge(opts))

        server.mount_proc '/' do |_, res|
          res.status = 200
          res.body = "webrick #{certificate.subject}"
        end

        server
      end

      def inject_custom_trust_store(*certificates)
        store = OpenSSL::X509::Store.new
        certificates.each do |certificate|
          store.add_cert(certificate)
        end

        expect(::Net::HTTP).to receive(:start).exactly(certificates.length).times
          .and_wrap_original do |orig, *args, &block|

          args.last[:cert_store] = store # Inject our custom trust store
          orig.call(*args, &block)
        end
      end

      it 'should successfully validate TLS certificates' do
        hostname = 'ssrf-filter.example.com'
        port = 8443
        private_key, certificate = make_keypair("CN=#{hostname}")
        stub_const('SsrfFilter::IPV4_BLACKLIST', [])

        inject_custom_trust_store(certificate)

        begin
          called = false
          rspec_thread = Thread.new do
            Thread.stop
            response = SsrfFilter.get("https://#{hostname}:#{port}", resolver: proc { [IPAddr.new('127.0.0.1')] })
            expect(response.code).to eq('200')
            expect(response.body).to eq('webrick /CN=ssrf-filter.example.com')
            called = true
          end

          server = make_web_server(port, private_key, certificate) do
            rspec_thread.wakeup
          end

          web_server_thread = Thread.new do
            server.start
          end

          Timeout.timeout(5) do
            rspec_thread.join
            expect(called).to be(true)
          end
        ensure
          rspec_thread.kill unless rspec_thread.nil?
          web_server_thread.kill unless web_server_thread.nil?
        end
      end

      it 'should successfully connect when using SNI' do
        # SNI was broken in WEBRick until the following commits on ruby-head:
        # https://github.com/ruby/ruby/commit/08bdbef5cabeb1a8b84b9ddf7a3137289620d46b
        # https://github.com/ruby/ruby/commit/a6c13d08d7d2035a22855c8f412694d13ba2faa0
        #
        # We need that for this test, so only execute if we're on a revision that has those commits
        return pending if RUBY_REVISION < 59351

        port = 8443
        private_key, certificate = make_keypair('CN=localhost')
        virtualhost_private_key, virtualhost_certificate = make_keypair('CN=virtualhost')
        stub_const('SsrfFilter::IPV4_BLACKLIST', [])

        inject_custom_trust_store(certificate, virtualhost_certificate)

        begin
          called = false
          rspec_thread = Thread.new do
            Thread.stop
            options = {
              resolver: proc { [IPAddr.new('127.0.0.1')] }
            }

            response = SsrfFilter.get("https://localhost:#{port}", options)
            expect(response.code).to eq('200')
            expect(response.body).to eq('webrick /CN=localhost')

            response = SsrfFilter.get("https://virtualhost:#{port}", options)
            expect(response.code).to eq('200')
            expect(response.body).to eq('webrick /CN=virtualhost')

            called = true
          end

          server = make_web_server(port, private_key, certificate, ServerName: 'localhost') do
            rspec_thread.wakeup
          end

          options = {ServerName: 'virtualhost', DoNotListen: true}
          virtualhost = make_web_server(port, virtualhost_private_key, virtualhost_certificate, options)
          server.virtual_host(virtualhost)

          web_server_thread = Thread.new do
            server.start
          end

          Timeout.timeout(5) do
            rspec_thread.join
            expect(called).to be(true)
          end
        ensure
          rspec_thread.kill unless rspec_thread.nil?
          web_server_thread.kill unless web_server_thread.nil?
        end
      end
    end
  end

  context 'get/put/post/delete' do
    it 'should fail if the scheme is not in the default whitelist' do
      expect do
        SsrfFilter.get('ftp://example.com')
      end.to raise_error(SsrfFilter::InvalidUriScheme)
    end

    it 'should fail if the scheme is not in a custom whitelist' do
      expect do
        SsrfFilter.get('https://example.com', scheme_whitelist: [])
      end.to raise_error(SsrfFilter::InvalidUriScheme)
    end

    it 'should fail if the hostname does not resolve' do
      expect(Resolv).to receive(:getaddresses).and_return([])
      expect do
        SsrfFilter.get('https://example.com')
      end.to raise_error(SsrfFilter::UnresolvedHostname)
    end

    it 'should fail if the hostname does not resolve with a custom resolver' do
      called = false
      resolver = proc do
        called = true
        []
      end

      expect(SsrfFilter::DEFAULT_RESOLVER).to_not receive(:call)
      expect do
        SsrfFilter.get('https://example.com', resolver: resolver)
      end.to raise_error(SsrfFilter::UnresolvedHostname)
      expect(called).to be(true)
    end

    it 'should fail if the hostname has no public ip address' do
      expect(SsrfFilter::DEFAULT_RESOLVER).to receive(:call).and_return([private_ipv4])
      expect do
        SsrfFilter.get('https://example.com')
      end.to raise_error(SsrfFilter::PrivateIPAddress)
    end

    it 'should fail if there are too many redirects' do
      stub_request(:get, "https://#{public_ipv4}").with(headers: {host: 'www.example.com:443'}).to_return(
        status: 301, headers: {location: private_ipv4})
      resolver = proc { [public_ipv4] }
      expect do
        SsrfFilter.get('https://www.example.com', resolver: resolver, max_redirects: 0)
      end.to raise_error(SsrfFilter::TooManyRedirects)
    end

    it 'should fail if the redirected url is not in the scheme whitelist' do
      stub_request(:put, "https://#{public_ipv4}").with(headers: {host: 'www.example.com:443'}).to_return(
        status: 301, headers: {location: 'ftp://www.example.com'})
      resolver = proc { [public_ipv4] }
      expect do
        SsrfFilter.put('https://www.example.com', resolver: resolver)
      end.to raise_error(SsrfFilter::InvalidUriScheme)
    end

    it 'should fail if the redirected url has no public ip address' do
      stub_request(:delete, "https://#{public_ipv4}").with(headers: {host: 'www.example.com:443'}).to_return(
        status: 301, headers: {location: 'https://www.example2.com'})
      resolver = proc do |hostname|
        [{
          'www.example.com' => public_ipv4,
          'www.example2.com' => private_ipv6
        }[hostname]]
      end
      expect do
        SsrfFilter.delete('https://www.example.com', resolver: resolver)
      end.to raise_error(SsrfFilter::PrivateIPAddress)
    end

    it 'should follow redirects and succeed on a public hostname' do
      stub_request(:post, "https://#{public_ipv4}/path?key=value").with(headers: {host: 'www.example.com:443'})
        .to_return(status: 301, headers: {location: 'https://www.example2.com/path2?key2=value2'})
      stub_request(:post, "https://#{public_ipv6}/path2?key2=value2").with(
        headers: {host: 'www.example2.com:443'}).to_return(status: 200, body: 'response body')
      resolver = proc do |hostname|
        [{
          'www.example.com' => public_ipv4,
          'www.example2.com' => public_ipv6
        }[hostname]]
      end
      response = SsrfFilter.post('https://www.example.com/path?key=value', resolver: resolver)
      expect(response.code).to eq('200')
      expect(response.body).to eq('response body')
    end
  end
end