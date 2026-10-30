using System.Net;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;

namespace RPA.CPH.NonSubsidy.Web.Tests;

internal sealed class RazorPagesApplication : IDisposable
{
    private readonly SqliteConnection connection = new("Data Source=:memory:;Foreign Keys=True");
    internal AuthenticationHostTests.OfflineApplication Factory { get; }
    internal HttpClient Client { get; }

    internal RazorPagesApplication(string environment = "Production")
    {
        connection.Open();
        RelationalPersistenceTests.CreateHistoricalSchema(connection);
        Factory = new AuthenticationHostTests.OfflineApplication(services =>
        {
            services.RemoveAll<CPHContext>();
            services.RemoveAll<DbContextOptions<CPHContext>>();
            services.RemoveAll<IDbContextOptionsConfiguration<CPHContext>>();
            services.AddDbContext<CPHContext>(options => options.UseSqlite(connection));
            services.RemoveAll<IUnitOfWork>();
            services.AddScoped<IUnitOfWork, UnitOfWork>();
        }, environment);
        Client = Factory.Client();
    }

    internal CPHContext Context() => new(new DbContextOptionsBuilder<CPHContext>().UseSqlite(connection).Options);
    internal async Task Login() =>
        Assert.AreEqual(HttpStatusCode.OK, (await Client.PostAsync("/__test/session?role=Test.BasicAccess", null)).StatusCode);

    internal static Dictionary<string, string> Fields(string html)
    {
        var fields = new Dictionary<string, string>();
        foreach (Match input in Regex.Matches(html, "<input\\b[^>]*>", RegexOptions.IgnoreCase))
        {
            string Attribute(string name) => WebUtility.HtmlDecode(
                Regex.Match(input.Value, $"\\b{name}=\"([^\"]*)\"").Groups[1].Value);
            var name = Attribute("name");
            if (name.Length == 0 || Attribute("type") == "checkbox") continue;
            fields.TryAdd(name, Attribute("value"));
        }
        return fields;
    }

    internal static void Valid(Dictionary<string, string> form)
    {
        form["SBI"] = "105000001";
        form["BusinessName"] = "Farm <script>alert('x')</script>";
        form["Address1"] = "1 High Street";
        form["PostCode"] = "ls1 1aa";
        form["CRMCaseReferenceNumber"] = "CRM1";
        form["County"] = "01";
        form["Parish"] = "002";
        form["Holding"] = "0003";
        form["submit"] = "save";
    }

    internal static void Parcel(Dictionary<string, string> form, string index, string grid, bool pob, int id = 0, int landId = 0, bool active = true)
    {
        var prefix = $"LandParcels[{index}].";
        form[prefix + "GridReference"] = grid;
        form[prefix + "PlaceOfBusiness"] = pob.ToString();
        form[prefix + "Active"] = active.ToString();
        form[prefix + "LandParcelId"] = id.ToString();
        form[prefix + "LandId"] = landId.ToString();
    }

    internal Task<HttpResponseMessage> Post(Dictionary<string, string> form, params string[] indices) =>
        Client.PostAsync("/Home/Customer", new FormUrlEncodedContent(form.Where(x => x.Key != "LandParcels.index")
            .Concat(indices.Select(index => new KeyValuePair<string, string>("LandParcels.index", index)))));

    public void Dispose()
    {
        Client.Dispose();
        Factory.Dispose();
        connection.Dispose();
    }
}

[TestClass]
[TestCategory("Integration")]
public class RazorPagesWorkflowTests
{
    [TestMethod]
    public async Task CookieWorkflow_RendersBindsCreatesUpdatesInactivatesExtractsAndDeletes()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var html = await app.Client.GetStringAsync("/Home/Customer");
        StringAssert.Contains(html, "Customer Details");
        StringAssert.Contains(html, "name=\"County\" type=\"text\" value=\"\"");
        StringAssert.Contains(html, "name=\"Parish\" type=\"text\" value=\"\"");
        StringAssert.Contains(html, "name=\"Holding\" type=\"text\" value=\"\"");
        Assert.IsFalse(html.Contains("Last updated by"));
        var form = RazorPagesApplication.Fields(html);
        RazorPagesApplication.Valid(form);
        Assert.AreEqual(HttpStatusCode.BadRequest, (await app.Post(new(form) { ["__RequestVerificationToken"] = "invalid" })).StatusCode);
        using (var empty = app.Context()) Assert.AreEqual(0, empty.Customers.Count());
        RazorPagesApplication.Parcel(form, "first", "SK12345678", true);
        RazorPagesApplication.Parcel(form, "second", "SK87654321", false);
        Assert.AreEqual(HttpStatusCode.Redirect, (await app.Post(form, "first", "second")).StatusCode);
        int id, landId, firstId, secondId;
        using (var context = app.Context())
        {
            var customer = context.Customers.Include(x => x.Audit).Include(x => x.Land).ThenInclude(x => x.LandParcels).Single();
            id = customer.CustomerId;
            landId = customer.Land.Single().LandId;
            var parcels = customer.Land.Single().LandParcels.OrderBy(x => x.LandParcelId).ToArray();
            firstId = parcels[0].LandParcelId;
            secondId = parcels[1].LandParcelId;
            Assert.AreEqual("m1234", customer.Audit.LastUpdatedBy);
            Assert.IsTrue(customer.Audit.LastUpdated > DateTime.Now.AddMinutes(-2));
        }
        html = await app.Client.GetStringAsync($"/Home/Customer?customerId={id}");
        StringAssert.Contains(WebUtility.HtmlDecode(html), "Last updated by m1234 on " + DateTime.Now.ToString("dd/MM/yyyy", System.Globalization.CultureInfo.GetCultureInfo("en-GB")));
        StringAssert.Contains(html, "value=\"01\"");
        StringAssert.Contains(html, "value=\"002\"");
        StringAssert.Contains(html, "value=\"0003\"");
        Assert.IsFalse(html.Contains("<script>alert('x')</script>"));
        form = RazorPagesApplication.Fields(html);
        form["BusinessName"] = "Updated Farm";
        form["LastUpdatedBy"] = "forged";
        form["LastUpdated"] = "01/01/2000";
        form["submit"] = "save";
        // Explicit nonnumeric indices exercise the same binding contract as dynamically added rows.
        foreach (var key in form.Keys.Where(x => x.StartsWith("LandParcels[")).ToArray()) form.Remove(key);
        RazorPagesApplication.Parcel(form, "kept", "SK12345678", true, firstId, landId);
        RazorPagesApplication.Parcel(form, "removed", "SK87654321", false, secondId, landId, false);
        RazorPagesApplication.Parcel(form, "added", "SK22222222", false, 0, landId);
        Assert.AreEqual(HttpStatusCode.Redirect, (await app.Post(form, "kept", "removed", "added")).StatusCode);
        using (var context = app.Context())
        {
            Assert.AreEqual(3, context.LandParcels.Count());
            Assert.IsFalse(context.LandParcels.Single(x => x.LandParcelId == secondId).Active);
            Assert.AreEqual("Updated Farm", context.Customers.Single().BusinessName);
            Assert.AreEqual("m1234", context.Audit.Single().LastUpdatedBy);
            Assert.IsTrue(context.Audit.Single().LastUpdated > DateTime.Now.AddMinutes(-2));
        }
        var extract = await app.Client.GetAsync("/Home/Extract");
        Assert.AreEqual("text/csv", extract.Content.Headers.ContentType.MediaType);
        var csv = await extract.Content.ReadAsStringAsync();
        StringAssert.Contains(csv, "\"Updated Farm\"");
        StringAssert.Contains(csv, "\"SK22222222\"");
        Assert.IsFalse(csv.Contains("SK87654321"));
        var list = await app.Client.GetStringAsync("/");
        StringAssert.Contains(list, "01/002/0003");
        StringAssert.Contains(list, "SK12345678, SK22222222");
        form = RazorPagesApplication.Fields(await app.Client.GetStringAsync($"/Home/Customer?customerId={id}"));
        form["submit"] = "delete";
        form["SBI"] = "not-an-integer";
        Assert.AreEqual(HttpStatusCode.Redirect, (await app.Post(form)).StatusCode);
        using (var context = app.Context())
        {
            Assert.AreEqual(0, context.Customers.Count());
            Assert.AreEqual(0, context.Addresses.Count());
            Assert.AreEqual(0, context.Land.Count());
            Assert.AreEqual(0, context.LandParcels.Count());
            Assert.AreEqual(0, context.Case.Count());
            Assert.AreEqual(0, context.Audit.Count());
        }
        StringAssert.Contains(await app.Client.GetStringAsync("/"), "No customer data has been created.");
    }

    [TestMethod]
    [DataRow("Address1", "", "First line of Address is required.")]
    [DataRow("Address1", "   ", "First line of Address is required.")]
    [DataRow("PostCode", "", "Post Code is required.")]
    [DataRow("PostCode", "   ", "Post Code is required.")]
    [DataRow("PostCode", "invalid", "Invalid Post Code.")]
    [DataRow("CRMCaseReferenceNumber", "", "CRM Reference must be provided.")]
    [DataRow("BusinessName", "   ", "Business Name is required.")]
    [DataRow("SBI", "104999999", "Invalid SBI.")]
    [DataRow("SBI", "", "The value '' is invalid.")]
    [DataRow("County", "100", "Invalid County.")]
    [DataRow("County", "0", "Invalid County.")]
    [DataRow("Parish", "1000", "Invalid Parish.")]
    [DataRow("Holding", "10000", "Invalid Holding.")]
    [DataRow("Holding", "abc", "The value 'abc' is not valid for Holding.")]
    [DataRow("County", null, "Invalid County.")]
    [DataRow("Parish", "", "The value '' is invalid.")]
    [DataRow("Holding", " ", "The value ' ' is invalid.")]
    [DataRow("SBI", "abc", "The value 'abc' is not valid for SBI.")]
    [DataRow("SBI", null, "Invalid SBI.")]
    [DataRow("CRMCaseReferenceNumber", null, "CRM Reference must be provided.")]
    [DataRow("Address1", null, "First line of Address is required.")]
    public async Task InvalidForm_RedisplaysExactValidationAndPreservesCollectionIndicesWithoutWrites(string field, string value, string error)
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var form = RazorPagesApplication.Fields(await app.Client.GetStringAsync("/Home/Customer"));
        RazorPagesApplication.Valid(form);
        form[field] = value;
        if (value == null) form.Remove(field);
        RazorPagesApplication.Parcel(form, "row-one", "SK12345678", true);
        RazorPagesApplication.Parcel(form, "row-two", "SK87654321", false);
        var response = await app.Post(form, "row-one", "row-two");
        Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);
        var html = await response.Content.ReadAsStringAsync();
        StringAssert.Contains(WebUtility.HtmlDecode(html), error);
        StringAssert.Contains(html, "name=\"LandParcels[row-one].GridReference\"");
        StringAssert.Contains(html, "name=\"LandParcels[row-two].GridReference\"");
        StringAssert.Contains(html, "value=\"SK87654321\"");
        Assert.AreEqual("False", RazorPagesApplication.Fields(html)["IsUpdate"]);
        using var context = app.Context();
        Assert.AreEqual(0, context.Customers.Count());
        Assert.AreEqual(0, context.Audit.Count());
    }

    [TestMethod]
    public async Task FilteredBlankNewParcel_DoesNotStealRetainedRowsIndexOnInvalidRedisplay()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var form = RazorPagesApplication.Fields(await app.Client.GetStringAsync("/Home/Customer"));
        RazorPagesApplication.Valid(form);
        form["Address1"] = "";
        RazorPagesApplication.Parcel(form, "discard-blank", "", false);
        RazorPagesApplication.Parcel(form, "retain-row", "SK12345678", true);
        var response = await app.Post(form, "discard-blank", "retain-row");
        Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);
        var html = await response.Content.ReadAsStringAsync();
        var fields = RazorPagesApplication.Fields(html);
        Assert.AreEqual("retain-row", fields["LandParcels.index"]);
        Assert.AreEqual("SK12345678", fields["LandParcels[retain-row].GridReference"]);
        Assert.IsFalse(html.Contains("LandParcels[discard-blank]"));
        fields["Address1"] = "Restored";
        fields["LandParcels[retain-row].PlaceOfBusiness"] = "true";
        fields["submit"] = "save";
        Assert.AreEqual(HttpStatusCode.Redirect, (await app.Post(fields, "retain-row")).StatusCode);
        using var context = app.Context();
        Assert.AreEqual("SK12345678", context.LandParcels.Single().GridReference);
    }

    [TestMethod]
    [DataRow(0)]
    [DataRow(-1)]
    [DataRow(int.MaxValue)]
    public async Task MissingCustomer_ReturnsNotFound(int customerId)
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var response = await app.Client.GetAsync($"/Home/Customer?customerId={customerId}");
        Assert.AreEqual(HttpStatusCode.NotFound, response.StatusCode);
        var html = await response.Content.ReadAsStringAsync();
        Assert.IsFalse(html.Contains("NullReferenceException"));
    }

    [TestMethod]
    public async Task ParcelPartials_RenderDefaultsSuppliedValuesAndEncodedIndices()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var html = await app.Client.GetStringAsync("/Home/_NewLandParcel?landId=42");
        var fields = RazorPagesApplication.Fields(html);
        var index = fields["LandParcels.index"];
        Assert.AreEqual("42", fields[$"LandParcels[{index}].LandId"]);
        Assert.AreEqual("0", fields[$"LandParcels[{index}].LandParcelId"]);
        Assert.AreEqual("True", fields[$"LandParcels[{index}].Active"]);
        Assert.IsFalse(Regex.IsMatch(html, "checked=\"checked\""));
        var supplied = await app.Client.GetStringAsync("/Home/_LandParcel?LandId=9&LandParcelId=7&Active=false&GridReference=SK12345678&PlaceOfBusiness=true");
        fields = RazorPagesApplication.Fields(supplied);
        index = fields["LandParcels.index"];
        Assert.AreEqual("9", fields[$"LandParcels[{index}].LandId"]);
        Assert.AreEqual("7", fields[$"LandParcels[{index}].LandParcelId"]);
        Assert.AreEqual("False", fields[$"LandParcels[{index}].Active"]);
        StringAssert.Contains(supplied, "checked=\"checked\"");
    }

    [TestMethod]
    public async Task PagingAndSearch_RenderCountsOrderingAndPreserveSearch()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        using (var context = app.Context())
        {
            for (var i = 0; i < 23; i++)
                context.Customers.Add(new() { SBI = 105000000 + i, BusinessName = "Farm", Audit = new() { LastUpdated = new DateTime(2026, 1, 1) } });
            context.SaveChanges();
        }
        var first = await app.Client.GetStringAsync("/");
        StringAssert.Contains(first, "Showing 1 to 20 of 23 customers");
        Assert.IsTrue(first.IndexOf("105000000</td>") < first.IndexOf("105000019</td>"));
        var second = await app.Client.GetStringAsync("/?page=2&pageSize=20");
        StringAssert.Contains(second, "Showing 21 to 23 of 23 customers");
        StringAssert.Contains(second, "pageSize=20");
        Assert.IsFalse(second.Contains("105000019</td>"));
        var exact = await app.Client.GetStringAsync("/?searchString=%20105000001%20&pageSize=1");
        StringAssert.Contains(exact, "Showing 1 to 1 of 1 customers");
        Assert.IsFalse(exact.Contains("105000002</td>"));
        foreach (var search in new[] { "Farm", "105000" })
            StringAssert.Contains(await app.Client.GetStringAsync("/?searchString=" + search), "No customer data has been created.");
        StringAssert.Contains(await app.Client.GetStringAsync("/?searchString=%20%20"), "Showing 1 to 20 of 23 customers");
        using (var context = app.Context())
        {
            context.Customers.Add(new() { SBI = 105000001, BusinessName = "Duplicate SBI permitted", Audit = new() { LastUpdated = new DateTime(2026, 1, 2) } });
            context.SaveChanges();
        }
        var filtered = await app.Client.GetStringAsync("/?searchString=105000001&pageSize=1");
        StringAssert.Contains(filtered, "Showing 1 to 1 of 2 customers");
        var hrefs = Regex.Matches(filtered, "href=\"([^\"]+)\"").Select(x => WebUtility.HtmlDecode(x.Groups[1].Value));
        var next = hrefs.First(x => x.Contains("page=2"));
        StringAssert.Contains(next, "SearchString=105000001");
        var filteredSecond = await app.Client.GetStringAsync(next);
        StringAssert.Contains(filteredSecond, "Showing 2 to 2 of 2 customers");
        StringAssert.Contains(filteredSecond, "105000001</td>");
        Assert.IsFalse(filteredSecond.Contains("105000000</td>"));
        Assert.AreEqual("105000001", RazorPagesApplication.Fields(filteredSecond)["searchString"]);
        foreach (var size in new[] { 101, int.MaxValue })
            StringAssert.Contains(await app.Client.GetStringAsync($"/?pageSize={size}"), "Showing 1 to 24 of 24 customers");
        var beyond = await app.Client.GetStringAsync("/?page=99&pageSize=20");
        StringAssert.Contains(beyond, "No customer data has been created.");
    }

    [TestMethod]
    [DataRow("/?page=0")]
    [DataRow("/?page=-1")]
    [DataRow("/?pageSize=0")]
    [DataRow("/?pageSize=-1")]
    [DataRow("/?page=invalid")]
    [DataRow("/?pageSize=invalid")]
    [DataRow("/?page=2147483648")]
    [DataRow("/?pageSize=2147483648")]
    [DataRow("/?page=")]
    [DataRow("/?pageSize=")]
    [DataRow("/Home/Index?page=0")]
    [DataRow("/Home?pageSize=0")]
    public async Task InvalidPaging_ReturnsBadRequest(string path)
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var response = await app.Client.GetAsync(path);
        Assert.AreEqual(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.AreEqual("page and pageSize must be positive integers.", await response.Content.ReadAsStringAsync());
    }

    [TestMethod]
    [DataRow("Production", false)]
    [DataRow("Development", true)]
    public async Task ErrorRazor_OnlyDevelopmentDisplaysEncodedException(string environment, bool details)
    {
        using var app = new RazorPagesApplication(environment);
        var html = await app.Client.GetStringAsync("/Error");
        StringAssert.Contains(html, "For application support");
        Assert.IsFalse(html.Contains("Error Details:"));
        var response = await app.Client.GetAsync("/__test/error-view");
        html = await response.Content.ReadAsStringAsync();
        StringAssert.Contains(html, "Application Error");
        Assert.AreEqual(details, html.Contains("private-diagnostic"));
        Assert.IsFalse(html.Contains("<script>private-diagnostic</script>"));
        if (!details)
        {
            response = await app.Client.GetAsync("/__test/throw");
            Assert.AreEqual(HttpStatusCode.InternalServerError, response.StatusCode);
            html = await response.Content.ReadAsStringAsync();
            StringAssert.Contains(html, "For application support");
            Assert.IsFalse(html.Contains("private-diagnostic"));
            Assert.IsFalse(html.Contains("StackTrace"));
        }
    }

    [TestMethod]
    public async Task StaticResources_AreServedWithMimeTypesAndLayoutUsesLocalReferences()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var html = await app.Client.GetStringAsync("/Home/Customer");
        foreach (Match reference in Regex.Matches(html, "(?:src|href)=\"(/[^\"]+)\""))
        {
            var path = reference.Groups[1].Value;
            if (!new[] { "/Scripts/", "/Content/", "/assets/", "/images/" }.Any(path.StartsWith)) continue;
            var response = await app.Client.GetAsync(path);
            Assert.AreEqual(HttpStatusCode.OK, response.StatusCode, path);
            Assert.IsTrue((await response.Content.ReadAsByteArrayAsync()).Length > 0, path);
            if (path.EndsWith(".css")) Assert.AreEqual("text/css", response.Content.Headers.ContentType.MediaType);
            if (path.EndsWith(".js")) Assert.IsTrue(response.Content.Headers.ContentType.MediaType.Contains("javascript"));
            Assert.IsFalse(path.Contains('~'));
        }
        Assert.AreEqual(HttpStatusCode.NotFound, (await app.Client.GetAsync("/Content/img/uiTabsArrow.png")).StatusCode);
    }
}

// Only registered by the offline factory's test assembly application part.
[AllowAnonymous]
public sealed class TestErrorController : Controller
{
    [HttpGet("/__test/throw")]
    [HttpPost("/__test/throw")]
    public IActionResult Throw() => throw new InvalidOperationException("<script>private-diagnostic</script>");

    [HttpGet("/__test/error-view")]
    public IActionResult ErrorView()
    {
        HttpContext.Features.Set<IExceptionHandlerFeature>(new ExceptionHandlerFeature
        {
            Error = new InvalidOperationException("<script>private-diagnostic</script>")
        });
        return View("~/Pages/Shared/_Error.cshtml", HttpContext.Features.Get<IExceptionHandlerFeature>().Error);
    }
}
