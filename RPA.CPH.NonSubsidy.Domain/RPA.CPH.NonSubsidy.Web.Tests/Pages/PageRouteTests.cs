using System.Net;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc.Controllers;
using Microsoft.AspNetCore.Mvc.Infrastructure;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Abstractions;
using Microsoft.AspNetCore.Mvc.Routing;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.AspNetCore.Razor.Hosting;
using Microsoft.Extensions.DependencyInjection;
using RPA.CPH.NonSubsidy.Web.Services;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;

namespace RPA.CPH.NonSubsidy.Web.Tests.Pages;

[TestClass]
public class PageRouteTests
{
    [TestMethod]
    [DataRow("/")]
    [DataRow("/Home")]
    [DataRow("/Home/Index")]
    [DataRow("/Home/Index/42")]
    [DataRow("/Home/Customer")]
    [DataRow("/Home/Customer/42")]
    [DataRow("/Home/Extract")]
    [DataRow("/Home/_LandParcel")]
    [DataRow("/Home/_NewLandParcel?landId=42")]
    [TestCategory("Integration")]
    public async Task LegacyDataRoutes_RequireAuthenticationAndExactBasicRole(string path)
    {
        using var app = new AuthenticationHostTests.OfflineApplication();
        using var anonymous = app.Client();
        var challenge = await anonymous.GetAsync(path);
        Assert.AreEqual(HttpStatusCode.Redirect, challenge.StatusCode);
        Assert.AreEqual("identity.invalid", challenge.Headers.Location.Host);
        using var wrongRole = app.Client();
        await wrongRole.PostAsync("/__test/session?role=test.basicaccess", null);
        var denied = await wrongRole.GetAsync(path);
        Assert.AreEqual(HttpStatusCode.Redirect, denied.StatusCode);
        Assert.AreEqual("/Account/AccessDenied", denied.Headers.Location.AbsolutePath);
        using var allowed = app.Client();
        await allowed.PostAsync("/__test/session?role=Test.BasicAccess", null);
        Assert.AreEqual(HttpStatusCode.OK, (await allowed.GetAsync(path)).StatusCode);
    }

    [TestMethod]
    [TestCategory("Integration")]
    public void CompiledUi_IsPagesOnlyAndUsesPageLevelAuthorization()
    {
        using var app = new AuthenticationHostTests.OfflineApplication();
        using var client = app.Client();
        var descriptors = app.Services.GetRequiredService<IActionDescriptorCollectionProvider>().ActionDescriptors.Items;
        var pages = descriptors.OfType<PageActionDescriptor>().ToArray();
        foreach (var name in new[] { "/Index", "/Customer", "/Extract", "/LandParcel", "/NewLandParcel" })
        {
            var matches = pages.Where(x => x.ViewEnginePath == name).ToArray();
            Assert.IsTrue(matches.Length > 0, name);
            foreach (var page in matches)
                Assert.IsTrue(page.EndpointMetadata.OfType<IAuthorizeData>()
                    .Any(x => x.Policy == ApplicationServices.BasicAccessPolicy), name);
        }
        Assert.IsFalse(descriptors.OfType<ControllerActionDescriptor>()
            .Any(x => x.ControllerTypeInfo.Assembly == typeof(Program).Assembly), "No production MVC controller workflow remains.");
        var items = new RazorCompiledItemLoader().LoadItems(typeof(Program).Assembly);
        Assert.IsTrue(items.Any(x => x.Identifier == "/Pages/Customer.cshtml"));
        Assert.IsTrue(items.Any(x => x.Identifier == "/Pages/Shared/_Customer.cshtml"));
        Assert.IsFalse(items.Any(x => x.Identifier.StartsWith("/Views/", StringComparison.Ordinal)));
    }

    [TestMethod]
    [DataRow("/Home/Customer")]
    [DataRow("/Home/Customer/42")]
    [TestCategory("Integration")]
    public async Task CustomerPost_LegacyRoutesKeepFlatFieldsAntiforgeryAndPageRedirect(string path)
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        var fields = RazorPagesApplication.Fields(await app.Client.GetStringAsync(path));
        RazorPagesApplication.Valid(fields);
        var missingToken = new Dictionary<string, string>(fields);
        missingToken.Remove("__RequestVerificationToken");
        Assert.AreEqual(HttpStatusCode.BadRequest,
            (await app.Client.PostAsync(path, new FormUrlEncodedContent(missingToken))).StatusCode);
        using (var empty = app.Context()) Assert.AreEqual(0, empty.Customers.Count());
        var result = await app.Client.PostAsync(path, new FormUrlEncodedContent(fields));
        Assert.AreEqual(HttpStatusCode.Redirect, result.StatusCode);
        var next = await app.Client.GetAsync(result.Headers.Location);
        Assert.AreEqual(HttpStatusCode.OK, next.StatusCode);
        StringAssert.Contains(await next.Content.ReadAsStringAsync(), "CPH Non Subsidy Cases");
        using var database = app.Context();
        Assert.AreEqual("Farm <script>alert('x')</script>", database.Customers.Single().BusinessName);
        Assert.AreEqual("m1234", database.Audit.Single().LastUpdatedBy);
    }

    [TestMethod]
    [TestCategory("Integration")]
    public async Task LinksAndPager_GenerateWorkingPagesWithoutReservedPageKeyCollision()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        using (var database = app.Context())
        {
            for (var i = 0; i < 3; i++)
                database.Customers.Add(new Customer(
                    new Address { Address1 = "Street", PostCode = "LS1 1AA" },
                    new Land { County = 1, Parish = 2, Holding = 3 },
                    new Case { CRMCaseReferenceNumber = "CRM" },
                    new Audit { LastUpdated = new DateTime(2026, 1, 1) })
                { SBI = 105000000 + i, BusinessName = "Farm" });
            database.SaveChanges();
        }
        var html = await app.Client.GetStringAsync("/Home/Index?pageSize=1");
        var hrefs = System.Text.RegularExpressions.Regex.Matches(html, "href=\"([^\"]+)\"")
            .Select(x => WebUtility.HtmlDecode(x.Groups[1].Value)).ToArray();
        var next = hrefs.First(x => x.Contains("page=2"));
        var second = await app.Client.GetStringAsync(next);
        StringAssert.Contains(second, "Showing 2 to 2 of 3 customers");
        StringAssert.Contains(second, "105000001</td>");
        Assert.IsFalse(second.Contains("105000000</td>"));
        foreach (var link in hrefs.Where(x => x.Contains("/Home/Customer") || x.Contains("/Home/Extract")))
            Assert.AreEqual(HttpStatusCode.OK, (await app.Client.GetAsync(link)).StatusCode, link);
    }

    [TestMethod]
    [DataRow("/Account/SignedOut", HttpStatusCode.OK, "You have signed out.")]
    [DataRow("/Account/AccessDenied", HttpStatusCode.Forbidden, "Access denied. The required application role has not been assigned.")]
    [DataRow("/Account/AuthenticationFailed", HttpStatusCode.Unauthorized, "Sign-in failed. Contact the application identity owner.")]
    [TestCategory("Integration")]
    public async Task AnonymousAccountPages_KeepExactPlainTextStatus(string path, HttpStatusCode status, string message)
    {
        using var app = new AuthenticationHostTests.OfflineApplication();
        using var client = app.Client();
        var response = await client.GetAsync(path);
        Assert.AreEqual(status, response.StatusCode);
        Assert.AreEqual("text/plain", response.Content.Headers.ContentType.MediaType);
        Assert.AreEqual(message, await response.Content.ReadAsStringAsync());
    }

    [TestMethod]
    [TestCategory("Integration")]
    public async Task ErrorAliases_AllowAnonymousGetAndPostReexecutionWithoutDisclosingDetails()
    {
        using var app = new AuthenticationHostTests.OfflineApplication();
        using var client = app.Client();
        foreach (var path in new[] { "/Error", "/Error/Index" })
        {
            foreach (var method in new[] { HttpMethod.Get, HttpMethod.Post })
            {
                var response = await client.SendAsync(new(method, path));
                Assert.AreEqual(HttpStatusCode.OK, response.StatusCode);
                var html = await response.Content.ReadAsStringAsync();
                StringAssert.Contains(html, "For application support");
                Assert.IsFalse(html.Contains("Error Details:"));
            }
        }

    }

    [TestMethod]
    [TestCategory("Integration")]
    public async Task FailedPost_ReexecutesAnonymousErrorPageWithSafe500()
    {
        using var app = new AuthenticationHostTests.OfflineApplication();
        using var client = app.Client();
        var response = await client.PostAsync("/__test/throw", new FormUrlEncodedContent([]));
        Assert.AreEqual(HttpStatusCode.InternalServerError, response.StatusCode);
        var html = await response.Content.ReadAsStringAsync();
        StringAssert.Contains(html, "For application support");
        Assert.IsFalse(html.Contains("private-diagnostic"));
        Assert.IsFalse(html.Contains("StackTrace"));
    }

    [TestMethod]
    [DataRow("/Home/Customer")]
    [DataRow("/Home/Customer/42")]
    [TestCategory("Integration")]
    public async Task UnauthorizedPost_IsRejectedBeforeMutationOnLegacyRoutes(string path)
    {
        using var app = new RazorPagesApplication();
        var anonymous = await app.Client.PostAsync(path, new FormUrlEncodedContent([]));
        Assert.AreEqual(HttpStatusCode.Redirect, anonymous.StatusCode);
        Assert.AreEqual("identity.invalid", anonymous.Headers.Location.Host);
        await app.Client.PostAsync("/__test/session?role=Other.Role", null);
        var denied = await app.Client.PostAsync(path, new FormUrlEncodedContent([]));
        Assert.AreEqual(HttpStatusCode.Redirect, denied.StatusCode);
        Assert.AreEqual("/Account/AccessDenied", denied.Headers.Location.AbsolutePath);
        using var database = app.Context();
        Assert.AreEqual(0, database.Customers.Count());
    }

    [TestMethod]
    [DataRow("/", "/")]
    [DataRow("/Home/Customer?customerId=42", "/Home/Customer?customerId=42")]
    [DataRow("https://other.invalid/", "/")]
    [DataRow("//other.invalid/", "/")]
    [TestCategory("Unit")]
    public void SignInHandler_PreservesLocalReturnUrlsOnly(string returnUrl, string expected)
    {
        var page = new RPA.CPH.NonSubsidy.Web.Pages.Account.SignInModel().WithPageContext();
        page.Url = new UrlHelper(new ActionContext(new DefaultHttpContext(), new RouteData(), new ActionDescriptor()));
        var result = (ChallengeResult)page.OnGet(returnUrl);
        Assert.AreEqual(expected, result.Properties.RedirectUri);
        CollectionAssert.AreEqual(new[] { "OpenIdConnect" }, result.AuthenticationSchemes.ToArray());
    }
}
