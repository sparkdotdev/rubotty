# frozen_string_literal: true

require "spec_helper"
require "rubotty/web"
require "rack/session/cookie"

# The scheme a proxied request appears to have arrived on, which decides whether
# a `secure` session cookie is written at all.
RSpec.describe Rubotty::Web::ProxiedScheme do
  def env_for(headers = {})
    Rack::MockRequest.env_for("http://rubotty.example.org/admin-panel/login", method: "POST").merge(headers)
  end

  def capture(env, **options)
    seen = nil
    described_class.new(->(inner) { seen = inner; [200, {}, []] }, **options).call(env)
    seen
  end

  it "marks a request forwarded as https secure" do
    seen = capture(env_for("HTTP_X_FORWARDED_PROTO" => "https"))

    expect(seen["rack.url_scheme"]).to eq("https")
    expect(seen["HTTPS"]).to eq("on")
    expect(Rack::Request.new(seen)).to be_ssl
  end

  # A proxy chain appends as it goes, so the client's own scheme is first and the
  # later entries are hops between proxies.
  it "reads the original client scheme from the front of a chain" do
    expect(capture(env_for("HTTP_X_FORWARDED_PROTO" => "https, http"))["rack.url_scheme"]).to eq("https")
  end

  # Traefik rewrites X-Forwarded-Proto to its own inbound scheme, so on the
  # Cloudflare tunnel this is the only header still telling the truth.
  it "believes cloudflare about the browser's scheme" do
    seen = capture(env_for("HTTP_CF_VISITOR" => %({"scheme":"https"})))

    expect(seen["rack.url_scheme"]).to eq("https")
  end

  it "is not fooled by cloudflare reporting plain http" do
    seen = capture(env_for("HTTP_CF_VISITOR" => %({"scheme":"http"})))

    expect(seen["rack.url_scheme"]).to eq("http")
  end

  it "leaves a genuinely plain request alone" do
    seen = capture(env_for)

    expect(seen["rack.url_scheme"]).to eq("http")
    expect(seen["HTTPS"]).not_to eq("on")
    expect(Rack::Request.new(seen)).not_to be_ssl
  end

  # Traefik sets the header from ITS OWN inbound scheme, which is http once
  # Cloudflare has already terminated the TLS, so the header alone cannot rescue
  # that deployment and the operator has to say so outright.
  it "can be told to assume tls when the proxy reports http" do
    expect(capture(env_for, assume_tls: true)["rack.url_scheme"]).to eq("https")
  end

  it "reads the override out of the environment it is given" do
    expect(described_class.assume_tls?("RUBOTTY_ASSUME_TLS" => "1")).to be(true)
    expect(described_class.assume_tls?("RUBOTTY_ASSUME_TLS" => "no")).to be(false)
    expect(described_class.assume_tls?({})).to be(false)
  end

  # The regression this class exists for, and the one the dashboard specs cannot
  # see because they run with DASHBOARD_COOKIE_INSECURE set.
  describe "a secure session cookie behind a TLS-terminating proxy" do
    let(:inner) do
      lambda do |env|
        env["rack.session"][:role] = "administrator"
        [303, { "location" => "/" }, []]
      end
    end

    # Session INSIDE, scheme fix OUTSIDE, the order {Rubotty::Web.assemble} uses.
    # The other way round the cookie is written by middleware that still believes
    # the request was http.
    def session_app(app) = Rack::Session::Cookie.new(app, secret: "s" * 64, secure: true)

    def set_cookie(response) = response[1]["set-cookie"] || response[1]["Set-Cookie"]

    # Rack writes NO Set-Cookie at all rather than a cookie it thinks would be
    # unusable, so the operator logs in, is redirected, arrives with no session
    # and is bounced back to the login form with nothing to explain it.
    it "is dropped silently when the app believes the request was plain http" do
      expect(set_cookie(session_app(inner).call(env_for))).to be_nil
    end

    it "is written once the forwarded scheme is honoured" do
      wrapped = described_class.new(session_app(inner))

      expect(set_cookie(wrapped.call(env_for("HTTP_X_FORWARDED_PROTO" => "https")))).to include("secure")
    end

    it "is written when tls is assumed outright" do
      wrapped = described_class.new(session_app(inner), assume_tls: true)

      expect(set_cookie(wrapped.call(env_for))).to include("secure")
    end
  end
end
