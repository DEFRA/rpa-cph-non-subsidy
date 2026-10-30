using System.Net;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging.Abstractions;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
public class ContainerConfigurationTests
{
    private sealed class ReadyCheck(bool healthy) : IHealthCheck
    {
        public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
            Task.FromResult(healthy ? HealthCheckResult.Healthy() : HealthCheckResult.Unhealthy("PRIVATE_DETAILS"));
    }

    [TestMethod]
    [DataRow(true, HttpStatusCode.OK, "Healthy")]
    [DataRow(false, HttpStatusCode.ServiceUnavailable, "Unhealthy")]
    [TestCategory("Integration")]
    public async Task HealthEndpoints_AreAnonymousMinimalAndHttpCompatible(bool ready, HttpStatusCode expected, string body)
    {
        using var application = new AuthenticationHostTests.OfflineApplication(services =>
            services.Configure<HealthCheckServiceOptions>(options =>
            {
                options.Registrations.Clear();
                options.Registrations.Add(new HealthCheckRegistration("sql", new ReadyCheck(ready), null, ["ready"]));
            }));
        using var client = application.Client();
        client.BaseAddress = new Uri("http://localhost");
        var live = await client.GetAsync("/health/live");
        Assert.AreEqual(HttpStatusCode.OK, live.StatusCode);
        Assert.AreEqual("Healthy", await live.Content.ReadAsStringAsync());
        var response = await client.GetAsync("/health/ready");
        Assert.AreEqual(expected, response.StatusCode);
        Assert.AreEqual(body, await response.Content.ReadAsStringAsync());
        Assert.IsFalse(response.Headers.Contains("Set-Cookie"));
        var home = await client.GetAsync("/");
        Assert.AreEqual(HttpStatusCode.TemporaryRedirect, home.StatusCode);
        Assert.AreEqual("https", home.Headers.Location.Scheme);
    }

    [TestMethod]
    [TestCategory("Unit")]
    public async Task SqlReadiness_ConnectionFailureReturnsNoPrivateDetails()
    {
        var configuration = RuntimeConfigurationTests.Configuration(new Dictionary<string, string>());
        var check = new SqlReadinessHealthCheck(configuration, NullLogger<SqlReadinessHealthCheck>.Instance);
        var result = await check.CheckHealthAsync(new HealthCheckContext());
        Assert.AreEqual(HealthStatus.Unhealthy, result.Status);
        Assert.IsNull(result.Exception);
        Assert.IsNull(result.Description);
    }
}
