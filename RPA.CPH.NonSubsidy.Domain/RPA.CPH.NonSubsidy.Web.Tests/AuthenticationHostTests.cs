using System.Net;
using System.Security.Claims;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using System.Collections.Concurrent;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
[TestCategory("Integration")]
public class AuthenticationHostTests
{
    internal sealed class CaptureChannel : ITelemetryChannel
    {
        public ConcurrentBag<ITelemetry> Items { get; } = [];
        public bool? DeveloperMode { get; set; }
        public string EndpointAddress { get; set; }
        public void Send(ITelemetry item) => Items.Add(item);
        public void Flush() { }
        public void Dispose() { }
    }

    internal sealed class OfflineApplication : WebApplicationFactory<Program>
    {
        private readonly CaptureChannel telemetry;
        private readonly Action<IServiceCollection> configure;
        private readonly string environment;
        private readonly string allowedHosts = "localhost";

        internal OfflineApplication(CaptureChannel telemetry)
        {
            this.telemetry = telemetry;
            environment = "Production";
        }

        internal OfflineApplication(Action<IServiceCollection> configure = null, string environment = "Production",
            string allowedHosts = "localhost")
        {
            this.configure = configure;
            this.environment = environment;
            this.allowedHosts = allowedHosts;
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment(environment);
            builder.UseSetting("https_port", "443");
            foreach (var pair in RuntimeConfigurationTests.Settings())
                builder.UseSetting(pair.Key, pair.Value);
            builder.UseSetting("AllowedHosts", allowedHosts);
            if (telemetry != null)
                builder.UseSetting("ApplicationInsights:ConnectionString",
                    "InstrumentationKey=33333333-3333-3333-3333-333333333333;IngestionEndpoint=https://unused.invalid/");
            builder.ConfigureAppConfiguration((_, configuration) =>
            {
                var settings = RuntimeConfigurationTests.Settings();
                settings["AllowedHosts"] = allowedHosts;
                if (telemetry != null)
                    settings["ApplicationInsights:ConnectionString"] =
                        "InstrumentationKey=33333333-3333-3333-3333-333333333333;IngestionEndpoint=https://unused.invalid/";
                configuration.AddInMemoryCollection(settings);
            });
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<IUnitOfWork>();
                services.AddScoped<IUnitOfWork, FakeUnitOfWork>();
                services.AddDataProtection().UseEphemeralDataProtectionProvider();
                if (telemetry != null)
                {
                    services.Configure<Microsoft.ApplicationInsights.AspNetCore.Extensions.ApplicationInsightsServiceOptions>(
                        TelemetryTests.DisableNetworkBackgroundModules);
                    services.RemoveAll<ITelemetryChannel>();
                    services.AddSingleton<ITelemetryChannel>(telemetry);
                }
                services.AddControllersWithViews().AddApplicationPart(typeof(TestSessionController).Assembly);
                services.AddTransient<IStartupFilter, TestControllerEndpoints>();
                services.PostConfigure<OpenIdConnectOptions>(OpenIdConnectDefaults.AuthenticationScheme, options =>
                {
                    options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(
                        new OpenIdConnectConfiguration
                        {
                            Issuer = "https://identity.invalid/tenant/v2.0",
                            AuthorizationEndpoint = "https://identity.invalid/authorize",
                            TokenEndpoint = "https://identity.invalid/token",
                            EndSessionEndpoint = "https://identity.invalid/logout"
                        });
                });
                configure?.Invoke(services);
            });
        }

        // Production has only Razor Pages; these offline authentication/failure fixtures
        // are explicitly mapped only inside the test host.
        internal sealed class TestControllerEndpoints : IStartupFilter
        {
            public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
            {
                next(app);
                app.UseEndpoints(endpoints => endpoints.MapControllers());
            };
        }

        public HttpClient Client() => CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("https://localhost"),
            AllowAutoRedirect = false,
            HandleCookies = true
        });
    }

    [TestMethod]
    public async Task AnonymousHome_ChallengesOidcWithoutMetadataNetworkCalls()
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        var response = await client.GetAsync("/");
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        StringAssert.Contains(response.Headers.Location.Query, "response_type=code");
    }

    [TestMethod]
    [DataRow("localhost", "/Account/SignedOut", HttpStatusCode.OK)]
    [DataRow("app.example.invalid", "/Account/SignedOut", HttpStatusCode.OK)]
    [DataRow("APP.EXAMPLE.INVALID", "/Account/SignedOut", HttpStatusCode.OK)]
    [DataRow("localhost:7143", "/Account/SignedOut", HttpStatusCode.OK)]
    [DataRow("unlisted.example.invalid", "/Account/SignedOut", HttpStatusCode.BadRequest)]
    [DataRow("app.example.invalid.unlisted.invalid", "/Account/SignedOut", HttpStatusCode.BadRequest)]
    [DataRow("app.example.invalid", "/health/live", HttpStatusCode.OK)]
    [DataRow("unlisted.example.invalid", "/health/live", HttpStatusCode.BadRequest)]
    public async Task HostFiltering_OnlyAcceptsConfiguredHosts(string host, string path, HttpStatusCode expected)
    {
        using var application = new OfflineApplication(allowedHosts: "localhost;app.example.invalid");
        using var client = application.Client();
        using var request = new HttpRequestMessage(HttpMethod.Get, path);
        request.Headers.Host = host;
        var response = await client.SendAsync(request);
        Assert.AreEqual(expected, response.StatusCode);
    }

    [TestMethod]
    [DataRow("Test.BasicAccess", HttpStatusCode.OK)]
    [DataRow("Other.Role", HttpStatusCode.Redirect)]
    public async Task RealCookie_PagePolicyUsesConfiguredRole(string role, HttpStatusCode expected)
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        var login = await client.PostAsync("/__test/session?role=" + Uri.EscapeDataString(role), null);
        Assert.AreEqual(HttpStatusCode.OK, login.StatusCode);
        var cookie = login.Headers.GetValues("Set-Cookie").Single(c => c.StartsWith("__Host-Cph.Auth="));
        StringAssert.Contains(cookie, "secure");
        StringAssert.Contains(cookie, "httponly");
        var cookieOptions = application.Services.GetRequiredService<Microsoft.Extensions.Options.IOptionsMonitor<CookieAuthenticationOptions>>()
            .Get(CookieAuthenticationDefaults.AuthenticationScheme);
        var value = cookie[..cookie.IndexOf(';')];
        var ticket = cookieOptions.TicketDataFormat.Unprotect(value[(value.IndexOf('=') + 1)..]);
        Assert.IsNotNull(ticket);
        Assert.AreEqual(TimeSpan.FromMinutes(30), ticket.Properties.ExpiresUtc - ticket.Properties.IssuedUtc);
        var response = await client.GetAsync("/");
        Assert.AreEqual(expected, response.StatusCode);
        if (expected == HttpStatusCode.Redirect)
        {
            StringAssert.Contains(response.Headers.Location.AbsolutePath, "/Account/AccessDenied");
            var denied = await client.GetAsync(response.Headers.Location);
            Assert.AreEqual(HttpStatusCode.Forbidden, denied.StatusCode);
        }
    }

    private sealed class CookieClock : TimeProvider
    {
        public DateTimeOffset UtcNow { get; set; } = new(2026, 10, 30, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => UtcNow;
    }

    [TestMethod]
    [DataRow(14, false, HttpStatusCode.OK)]
    [DataRow(16, true, HttpStatusCode.OK)]
    [DataRow(31, false, HttpStatusCode.Redirect)]
    public async Task CookieLifetime_RenewsAfterHalfLifeAndChallengesAfterExpiry(
        int elapsedMinutes, bool renewed, HttpStatusCode expected)
    {
        var clock = new CookieClock();
        using var application = new OfflineApplication(services =>
            services.PostConfigure<CookieAuthenticationOptions>(CookieAuthenticationDefaults.AuthenticationScheme,
                options => options.TimeProvider = clock));
        using var client = application.Client();
        Assert.AreEqual(HttpStatusCode.OK,
            (await client.PostAsync("/__test/session?role=Test.BasicAccess", null)).StatusCode);

        clock.UtcNow += TimeSpan.FromMinutes(elapsedMinutes);
        var response = await client.GetAsync("/");
        Assert.AreEqual(expected, response.StatusCode);
        var authCookies = response.Headers.TryGetValues("Set-Cookie", out var cookies)
            ? cookies.Where(cookie => cookie.StartsWith("__Host-Cph.Auth=")).ToArray() : [];
        Assert.AreEqual(renewed ? 1 : 0, authCookies.Length);

        if (renewed)
        {
            var options = application.Services.GetRequiredService<IOptionsMonitor<CookieAuthenticationOptions>>()
                .Get(CookieAuthenticationDefaults.AuthenticationScheme);
            var cookie = authCookies.Single().Split(';')[0];
            var ticket = options.TicketDataFormat.Unprotect(cookie["__Host-Cph.Auth=".Length..]);
            Assert.IsNotNull(ticket);
            Assert.AreEqual(clock.UtcNow, ticket.Properties.IssuedUtc);
            Assert.AreEqual(clock.UtcNow.AddMinutes(30), ticket.Properties.ExpiresUtc);

            clock.UtcNow += TimeSpan.FromMinutes(15);
            Assert.AreEqual(HttpStatusCode.OK, (await client.GetAsync("/")).StatusCode,
                "The renewed session must remain valid beyond the original thirty-minute expiry.");
        }
        else if (expected == HttpStatusCode.Redirect)
        {
            Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        }
    }

    [TestMethod]
    public async Task SignOut_RequiresAntiforgeryAndClearsCookieBeforeOidcRedirect()
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        await client.PostAsync("/__test/session?role=Test.BasicAccess", null);
        var rejected = await client.PostAsync("/Account/SignOut", new FormUrlEncodedContent([]));
        Assert.AreEqual(HttpStatusCode.BadRequest, rejected.StatusCode);
        var page = await client.GetStringAsync("/Account/SignOut");
        var token = Regex.Match(page, "name=\"__RequestVerificationToken\"[^>]*value=\"([^\"]+)\"").Groups[1].Value;
        Assert.IsFalse(string.IsNullOrEmpty(token));
        var response = await client.PostAsync("/Account/SignOut", new FormUrlEncodedContent(
            new Dictionary<string, string> { ["__RequestVerificationToken"] = WebUtility.HtmlDecode(token) }));
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        Assert.AreEqual("identity.invalid", response.Headers.Location.Host);
        StringAssert.Contains(response.Headers.Location.AbsolutePath, "/logout");
        Assert.IsTrue(response.Headers.GetValues("Set-Cookie")
            .Any(c => c.StartsWith("__Host-Cph.Auth=;") && c.Contains("expires=")));
    }

    [TestMethod]
    public async Task CustomerPost_RejectsCookieWithoutConfiguredBasicAccessRole()
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        await client.PostAsync("/__test/session?role=Other.Role", null);
        var deniedPost = await client.PostAsync("/Home/Customer", new FormUrlEncodedContent([]));
        Assert.AreEqual(HttpStatusCode.Redirect, deniedPost.StatusCode);
        StringAssert.Contains(deniedPost.Headers.Location.AbsolutePath, "/Account/AccessDenied");
    }

    [TestMethod]
    [DataRow("https://external.invalid/", "/")]
    [DataRow("//external.invalid/", "/")]
    [DataRow("/Home/Customer", "/Home/Customer")]
    public async Task SignIn_OnlyPreservesLocalReturnUrls(string returnUrl, string expected)
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        var response = await client.GetAsync("/Account/SignIn?returnUrl=" + Uri.EscapeDataString(returnUrl));
        Assert.AreEqual(HttpStatusCode.Redirect, response.StatusCode);
        var state = Microsoft.AspNetCore.WebUtilities.QueryHelpers.ParseQuery(response.Headers.Location.Query)["state"];
        var options = application.Services.GetRequiredService<Microsoft.Extensions.Options.IOptionsMonitor<OpenIdConnectOptions>>()
            .Get(OpenIdConnectDefaults.AuthenticationScheme);
        Assert.AreEqual(expected, options.StateDataFormat.Unprotect(state).RedirectUri);
    }

    [TestMethod]
    public void ConfiguredSdkPipeline_PreservesDiagnosticTelemetryAndCorrelationInMemory()
    {
        var channel = new CaptureChannel();
        using var application = new OfflineApplication(channel);
        var telemetry = application.Services.GetRequiredService<TelemetryClient>();
        var request = new RequestTelemetry
        {
            Name = "GET /synthetic-test",
            Url = new Uri("https://unused.invalid/synthetic-test"),
            ResponseCode = "201",
            Success = true,
            Duration = TimeSpan.FromMilliseconds(9)
        };
        request.Context.Operation.Id = "0123456789abcdef0123456789abcdef";
        request.Properties["fixture"] = "synthetic";
        telemetry.TrackRequest(request);
        telemetry.TrackTrace("synthetic trace");
        telemetry.TrackException(new Exception("synthetic exception"));
        telemetry.TrackDependency(new DependencyTelemetry
        {
            Type = "SQL", Name = "synthetic dependency", Target = "unused.invalid",
            Success = true, Duration = TimeSpan.FromMilliseconds(2)
        });
        telemetry.TrackEvent("synthetic event");
        telemetry.TrackMetric("synthetic metric", 1);
        telemetry.Flush();
        var exported = channel.Items.OfType<RequestTelemetry>().Single(item => item.Name == request.Name);
        Assert.AreEqual("201", exported.ResponseCode);
        Assert.AreEqual(request.Url, exported.Url);
        Assert.AreEqual(request.Context.Operation.Id, exported.Context.Operation.Id);
        Assert.AreEqual("synthetic", exported.Properties["fixture"]);
        Assert.IsTrue(channel.Items.OfType<TraceTelemetry>().Any(item => item.Message == "synthetic trace"));
        Assert.IsTrue(channel.Items.OfType<ExceptionTelemetry>().Any(item => item.Exception.Message == "synthetic exception"));
        Assert.IsTrue(channel.Items.OfType<DependencyTelemetry>().Any(item => item.Name == "synthetic dependency"));
        Assert.IsTrue(channel.Items.OfType<EventTelemetry>().Any(item => item.Name == "synthetic event"));
        Assert.IsTrue(channel.Items.OfType<MetricTelemetry>().Any(item => item.Name == "synthetic metric"));
    }

    [TestMethod]
    public async Task UntrustedForwardedProto_DoesNotBypassHttps()
    {
        using var application = new OfflineApplication();
        using var client = application.Client();
        using var request = new HttpRequestMessage(HttpMethod.Get, "http://localhost:5000/Account/SignedOut");
        request.Headers.Add("X-Forwarded-Proto", "https");
        var response = await client.SendAsync(request);
        Assert.AreEqual(HttpStatusCode.TemporaryRedirect, response.StatusCode);
        Assert.AreEqual("https", response.Headers.Location.Scheme);
    }
}

// This controller exists only in the test assembly; production never registers it.
[AllowAnonymous]
[Route("__test/session")]
public sealed class TestSessionController : Controller
{
    [HttpPost]
    public async Task<IActionResult> Create(string role)
    {
        var claims = new List<Claim> { new("test_audit_name", @"EARTH\M01234") };
        if (!string.IsNullOrEmpty(role)) claims.Add(new Claim("roles", role));
        await HttpContext.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme,
            new ClaimsPrincipal(new ClaimsIdentity(claims, "test-issued-cookie", "test_audit_name", "roles")));
        return Ok();
    }
}
