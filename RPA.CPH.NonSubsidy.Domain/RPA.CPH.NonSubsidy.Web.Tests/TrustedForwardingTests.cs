using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
public class TrustedForwardingTests
{
    [TestMethod]
    [DataRow("ReverseProxy:KnownIPNetworks:0", "0.0.0.0/0")]
    [DataRow("ReverseProxy:KnownIPNetworks:0", "::/0")]
    [DataRow("ReverseProxy:KnownIPNetworks:0", "10.42.0.1/23")]
    [DataRow("ReverseProxy:KnownIPNetworks:0", "10.42.0.0/33")]
    [DataRow("ReverseProxy:KnownIPNetworks:0", "not-a-network")]
    [DataRow("ReverseProxy:KnownProxies:0", "0.0.0.0")]
    [DataRow("ReverseProxy:KnownProxies:0", "::")]
    [DataRow("ReverseProxy:KnownProxies:0", "not-an-address")]
    [TestCategory("Unit")]
    public void InvalidTrustConfiguration_FailsAtApplicationRegistration(string key, string value)
    {
        var settings = RuntimeConfigurationTests.Settings();
        settings[key] = value;
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(RuntimeConfigurationTests.Configuration(settings)));
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void NetworkTrust_IsExplicitAndOneHop_WithoutHeaderCountSymmetry()
    {
        var services = new ServiceCollection();
        services.AddCphForwarding(RuntimeConfigurationTests.Configuration(new()
        {
            ["ReverseProxy:KnownIPNetworks:0"] = "10.42.0.0/23",
            ["ReverseProxy:KnownProxies:0"] = "192.0.2.1"
        }));
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<ForwardedHeadersOptions>>().Value;
        Assert.AreEqual(1, options.KnownIPNetworks.Count);
        Assert.IsTrue(options.KnownIPNetworks.Single().Contains(IPAddress.Parse("10.42.1.8")));
        Assert.IsFalse(options.KnownIPNetworks.Single().Contains(IPAddress.Parse("10.42.2.8")));
        Assert.AreEqual(1, options.KnownProxies.Count);
        Assert.AreEqual(1, options.ForwardLimit);
        Assert.IsFalse(options.RequireHeaderSymmetry);
        Assert.AreEqual(ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto, options.ForwardedHeaders);
    }

    [TestMethod]
    [DataRow("10.42.1.8", "198.51.100.8")]
    [DataRow("::ffff:10.42.1.8", "198.51.100.8")]
    [DataRow("10.42.1.8", "203.0.113.1, 198.51.100.8")]
    [DataRow("10.42.1.8", "spoofed-client-prefix, 198.51.100.8")]
    [TestCategory("Integration")]
    public async Task TrustedNetwork_HttpsChallengeUsesSecureExternalCallback(string remote, string forwardedFor)
    {
        using var application = Application(remote);
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        using var request = Request("/", "https", forwardedFor);
        var response = await client.SendAsync(request);
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        StringAssert.Contains(Uri.UnescapeDataString(response.Headers.Location.Query), "redirect_uri=https://localhost/signin-oidc");
        Assert.IsTrue(response.Headers.GetValues("Set-Cookie").All(cookie => cookie.Contains("; secure", StringComparison.OrdinalIgnoreCase)));
        Assert.AreEqual("198.51.100.8", response.Headers.GetValues("Test-Remote-IP").Single());
    }

    [TestMethod]
    [DataRow("192.0.2.22")]
    [DataRow("10.42.2.8")]
    [TestCategory("Integration")]
    public async Task UntrustedPeer_CannotSpoofHttps(string remote)
    {
        using var application = Application(remote);
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        var response = await client.SendAsync(Request("/", "https", "198.51.100.8"));
        Assert.AreEqual(HttpStatusCode.TemporaryRedirect, response.StatusCode);
        Assert.AreEqual("https://localhost/", response.Headers.Location.AbsoluteUri);
        Assert.AreEqual(remote, response.Headers.GetValues("Test-Remote-IP").Single());
    }

    [TestMethod]
    [DataRow("https,http", "198.51.100.8", HttpStatusCode.TemporaryRedirect)]
    [DataRow("ftp", "198.51.100.8", HttpStatusCode.TemporaryRedirect)]
    [DataRow("https", "invalid-rightmost", HttpStatusCode.TemporaryRedirect)]
    [DataRow("https", "", HttpStatusCode.Redirect)]
    [DataRow("", "198.51.100.8", HttpStatusCode.TemporaryRedirect)]
    [TestCategory("Integration")]
    public async Task TrustedPeer_ForwardingUsesFrameworkBehavior(string proto, string forwardedFor, HttpStatusCode expected)
    {
        using var application = Application("10.42.1.8");
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        var response = await client.SendAsync(Request("/", proto, forwardedFor));
        Assert.AreEqual(expected, response.StatusCode);
        if (expected == HttpStatusCode.Redirect)
        {
            Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
            StringAssert.Contains(Uri.UnescapeDataString(response.Headers.Location.Query), "redirect_uri=https://localhost/signin-oidc");
        }
        else
        {
            Assert.AreEqual("https://localhost/", response.Headers.Location.AbsoluteUri);
        }
    }

    [TestMethod]
    [DataRow("/health/live", HttpStatusCode.OK)]
    [DataRow("/", HttpStatusCode.TemporaryRedirect)]
    [TestCategory("Integration")]
    public async Task NoForwardingHeaders_LeavesHttpProbeAndApplicationBehaviorUnchanged(string path, HttpStatusCode expected)
    {
        using var application = Application("10.42.1.8");
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        Assert.AreEqual(expected, (await client.GetAsync(path)).StatusCode);
    }

    [TestMethod]
    [DataRow("192.0.2.1")]
    [DataRow("::ffff:192.0.2.1")]
    [TestCategory("Integration")]
    public async Task ExplicitProxy_AcceptsAsymmetricHeadersWithOneHopLimit(string remote)
    {
        using var application = Application(remote, network: false);
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        var response = await client.SendAsync(Request("/", "https", "203.0.113.1, 198.51.100.8"));
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        Assert.AreEqual("198.51.100.8", response.Headers.GetValues("Test-Remote-IP").Single());
        response = await client.SendAsync(Request("/", "https", "198.51.100.8"));
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        StringAssert.Contains(Uri.UnescapeDataString(response.Headers.Location.Query), "redirect_uri=https://localhost/signin-oidc");
    }

    private static AuthenticationHostTests.OfflineApplication Application(string remote, bool network = true) =>
        new(services =>
        {
            services.AddCphForwarding(RuntimeConfigurationTests.Configuration(new()
            {
                [network ? "ReverseProxy:KnownIPNetworks:0" : "ReverseProxy:KnownProxies:0"] =
                    network ? "10.42.0.0/23" : "192.0.2.1"
            }));
            services.AddSingleton<IStartupFilter>(new RemotePeer(remote));
        });

    private static HttpRequestMessage Request(string path, string proto, string forwardedFor)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, path);
        if (proto.Length > 0) request.Headers.TryAddWithoutValidation("X-Forwarded-Proto", proto);
        if (forwardedFor.Length > 0) request.Headers.TryAddWithoutValidation("X-Forwarded-For", forwardedFor);
        return request;
    }

    private sealed class RemotePeer(string address) : IStartupFilter
    {
        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.Use(async (context, handler) =>
            {
                context.Connection.RemoteIpAddress = IPAddress.Parse(address);
                context.Response.OnStarting(() =>
                {
                    context.Response.Headers["Test-Remote-IP"] = context.Connection.RemoteIpAddress?.ToString();
                    return Task.CompletedTask;
                });
                await handler(context);
            });
            next(app);
        };
    }
}
