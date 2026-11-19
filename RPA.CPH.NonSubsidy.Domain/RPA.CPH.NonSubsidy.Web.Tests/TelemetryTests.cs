using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using OpenTelemetry.Instrumentation.AspNetCore;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
[TestCategory("Unit")]
public class TelemetryTests
{
    private const string Connection =
        "InstrumentationKey=33333333-3333-3333-3333-333333333333;IngestionEndpoint=https://unused.invalid/";
    private const string Identity = "33333333-3333-3333-3333-333333333333";

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow(" ")]
    public void MissingOrBlankConnection_RegistersNoTelemetry(string connection)
    {
        var settings = new Dictionary<string, string>();
        if (connection != null)
            settings["APPLICATIONINSIGHTS_CONNECTION_STRING"] = connection;
        var services = Register(settings);

        Assert.IsFalse(services.Any(service => service.ServiceType == typeof(TracerProvider)));
        Assert.IsFalse(services.Any(service => service.ServiceType == typeof(MeterProvider)));
    }

    [TestMethod]
    [DataRow("")]
    [DataRow(" ")]
    public void BlankPrimaryConnection_DisablesEvenWhenFallbackIsConfigured(string connection)
    {
        var services = Register(new()
        {
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = connection,
            ["ApplicationInsights:ConnectionString"] = Connection
        });
        Assert.IsFalse(services.Any(service => service.ServiceType == typeof(TracerProvider)));
    }

    [TestMethod]
    [DataRow("APPLICATIONINSIGHTS_CONNECTION_STRING", true)]
    [DataRow("ApplicationInsights:ConnectionString", true)]
    [DataRow("APPLICATIONINSIGHTS_CONNECTION_STRING", false)]
    [DataRow("ApplicationInsights:ConnectionString", false)]
    public void ConfiguredTelemetry_RegistersDistroWithExplicitSettings(string connectionKey, bool enableIdentity)
    {
        var settings = new Dictionary<string, string> { [connectionKey] = Connection };
        if (connectionKey == "APPLICATIONINSIGHTS_CONNECTION_STRING")
            settings["ApplicationInsights:ConnectionString"] = "ignored";
        if (enableIdentity)
            settings["Telemetry:ManagedIdentityClientId"] = Identity;
        var services = Register(settings);

        Assert.IsTrue(services.Any(service => service.ServiceType == typeof(TracerProvider)));
        Assert.IsTrue(services.Any(service => service.ServiceType == typeof(MeterProvider)));
        // Resolve options only, not providers: no exporters, Live Metrics or metadata calls are started.
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<AzureMonitorOptions>>().Value;
        Assert.AreEqual(Connection, options.ConnectionString);
        if (enableIdentity)
            Assert.IsInstanceOfType<ManagedIdentityCredential>(options.Credential);
        else
            Assert.IsNull(options.Credential);
    }

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow(" ")]
    [DataRow("not-a-guid")]
    [DataRow("00000000-0000-0000-0000-000000000000")]
    [DataRow("DefaultAzureCredential")]
    public void InvalidManagedIdentity_FailsAtRegistration(string clientId)
    {
        var error = Assert.ThrowsExactly<InvalidOperationException>(() => Register(new()
        {
            ["Telemetry:ManagedIdentityClientId"] = clientId,
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = Connection
        }));
        StringAssert.Contains(error.Message, "Telemetry:ManagedIdentityClientId");
    }

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow(" ")]
    public void ManagedIdentityWithoutConnectionString_FailsInsteadOfDisablingTelemetry(string connection)
    {
        var error = Assert.ThrowsExactly<InvalidOperationException>(() => Register(new()
        {
            ["Telemetry:ManagedIdentityClientId"] = Identity,
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = connection,
            ["ApplicationInsights:ConnectionString"] = connection == null ? null : Connection
        }));
        StringAssert.Contains(error.Message, "Telemetry:ManagedIdentityClientId");
    }

    [TestMethod]
    [DataRow("/health/live", false)]
    [DataRow("/health/ready", false)]
    [DataRow("/Home/Customer", true)]
    [DataRow("/health/live-extra", true)]
    public void RequestTraceFilter_ExcludesOnlyProbePaths(string path, bool expected)
    {
        var services = Register(new() { ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = Connection });
        using var provider = services.BuildServiceProvider();
        var options = provider.GetRequiredService<IOptions<AspNetCoreTraceInstrumentationOptions>>().Value;
        var context = new DefaultHttpContext();
        context.Request.Path = path;

        Assert.AreEqual(expected, options.Filter(context));
    }

    private static ServiceCollection Register(Dictionary<string, string> settings)
    {
        var services = new ServiceCollection();
        services.AddCphApplicationInsights(RuntimeConfigurationTests.Configuration(settings));
        return services;
    }
}
