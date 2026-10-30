using System.Reflection;
using Azure.Identity;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.ApplicationInsights.Channel;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.ApplicationInsights.AspNetCore.Extensions;
using Microsoft.Extensions.DependencyInjection;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
public class TelemetryTests
{
    [TestMethod]
    [TestCategory("Unit")]
    public void UnconfiguredTelemetry_RegistersNoExporter()
    {
        var services = new ServiceCollection();
        services.AddCphApplicationInsights(RuntimeConfigurationTests.Configuration());
        Assert.IsFalse(services.Any(service => service.ServiceType == typeof(TelemetryConfiguration)));
    }

    [TestMethod]
    [DataRow("")]
    [DataRow(" ")]
    [DataRow("not-a-guid")]
    [DataRow("00000000-0000-0000-0000-000000000000")]
    [DataRow("DefaultAzureCredential")]
    [TestCategory("Unit")]
    public void InvalidManagedIdentity_FailsAtRegistration(string clientId)
    {
        var services = new ServiceCollection();
        var settings = new Dictionary<string, string>
        {
            ["Telemetry:ManagedIdentityClientId"] = clientId,
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = Connection
        };
        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            services.AddCphApplicationInsights(RuntimeConfigurationTests.Configuration(settings)));
        StringAssert.Contains(error.Message, "Telemetry:ManagedIdentityClientId");
    }

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    [DataRow(" ")]
    [TestCategory("Unit")]
    public void ManagedIdentityWithoutConnectionString_FailsInsteadOfDisablingTelemetry(string connection)
    {
        var services = new ServiceCollection();
        var settings = new Dictionary<string, string>
        {
            ["Telemetry:ManagedIdentityClientId"] = "33333333-3333-3333-3333-333333333333",
            ["APPLICATIONINSIGHTS_CONNECTION_STRING"] = connection
        };
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            services.AddCphApplicationInsights(RuntimeConfigurationTests.Configuration(settings)));
    }

    [TestMethod]
    [DataRow("APPLICATIONINSIGHTS_CONNECTION_STRING", true)]
    [DataRow("ApplicationInsights:ConnectionString", true)]
    [DataRow("APPLICATIONINSIGHTS_CONNECTION_STRING", false)]
    [TestCategory("Integration")]
    public void RealSdkConfiguration_UsesOnlyExplicitManagedIdentityWhenConfigured(string connectionKey, bool enableIdentity)
    {
        var builder = WebApplication.CreateBuilder();
        var settings = new Dictionary<string, string> { [connectionKey] = Connection };
        if (enableIdentity)
            settings["Telemetry:ManagedIdentityClientId"] = "33333333-3333-3333-3333-333333333333";
        builder.Services.AddCphApplicationInsights(RuntimeConfigurationTests.Configuration(settings));
        builder.Services.Configure<ApplicationInsightsServiceOptions>(DisableNetworkBackgroundModules);
        using var channel = new AuthenticationHostTests.CaptureChannel();
        builder.Services.RemoveAll<ITelemetryChannel>();
        builder.Services.AddSingleton<ITelemetryChannel>(channel);
        using var app = builder.Build();
        var configuration = app.Services.GetRequiredService<TelemetryConfiguration>();
        Assert.AreEqual(Connection, configuration.ConnectionString);
        // The SDK exposes its credential envelope internally, not as a public getter.
        var envelopeProperty = typeof(TelemetryConfiguration).GetProperty("CredentialEnvelope",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.IsNotNull(envelopeProperty);
        var envelope = envelopeProperty.GetValue(configuration);
        if (enableIdentity)
        {
            Assert.IsNotNull(envelope);
            var credentialProperty = envelope.GetType().GetProperty("Credential",
                BindingFlags.Instance | BindingFlags.NonPublic);
            Assert.IsNotNull(credentialProperty);
            Assert.IsInstanceOfType<ManagedIdentityCredential>(credentialProperty.GetValue(envelope));
        }
        else
        {
            Assert.IsNull(envelope);
        }
        Assert.IsFalse(channel.Items.OfType<RequestTelemetry>().Any());
    }

    private const string Connection =
        "InstrumentationKey=33333333-3333-3333-3333-333333333333;IngestionEndpoint=https://unused.invalid/";

    // Test hosts capture ingestion in memory; prevent separate Live Metrics/metadata network calls.
    internal static void DisableNetworkBackgroundModules(ApplicationInsightsServiceOptions options)
    {
        options.EnableQuickPulseMetricStream = false;
        options.EnableHeartbeat = false;
        options.EnableAppServicesHeartbeatTelemetryModule = false;
        options.EnableAzureInstanceMetadataTelemetryModule = false;
    }
}
