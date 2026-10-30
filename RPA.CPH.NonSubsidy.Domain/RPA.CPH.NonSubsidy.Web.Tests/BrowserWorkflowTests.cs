using Microsoft.Playwright;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
public class BrowserWorkflowTests
{
    [TestMethod]
    [TestCategory("Browser")]
    public async Task RealBrowser_DynamicParcelsValidateRemoveRebindAndPersist()
    {
        using var app = new RazorPagesApplication();
        await app.Login();
        using var playwright = await Playwright.CreateAsync();
        IBrowser browser;
        try
        {
            browser = await playwright.Chromium.LaunchAsync(new() { Channel = "msedge", Headless = true });
        }
        catch (PlaywrightException)
        {
            browser = await playwright.Chromium.LaunchAsync(new() { Channel = "chrome", Headless = true });
        }
        await using var ownedBrowser = browser;
        Console.WriteLine($"Actual browser: {browser.BrowserType.Name} {browser.Version}; intercepted localhost requests go to offline Razor Pages TestServer; all other origins blocked.");
        await using var context = await browser.NewContextAsync(new() { ServiceWorkers = ServiceWorkerPolicy.Block });
        var blocked = new List<string>();
        await context.RouteAsync("**/*", async route =>
        {
            var uri = new Uri(route.Request.Url);
            if (uri.Host != "localhost")
            {
                blocked.Add(uri.GetLeftPart(UriPartial.Authority));
                await route.AbortAsync();
                return;
            }
            using var request = new HttpRequestMessage(new HttpMethod(route.Request.Method), route.Request.Url);
            if (route.Request.PostDataBuffer != null)
            {
                request.Content = new ByteArrayContent(route.Request.PostDataBuffer);
                if (route.Request.Headers.TryGetValue("content-type", out var type))
                    request.Content.Headers.TryAddWithoutValidation("Content-Type", type);
            }
            var response = await app.Client.SendAsync(request);
            // Playwright routing does not intercept redirected requests: follow local page redirects
            // in the bridge so the browser can never fall through to a real network socket.
            for (var redirects = 0; (int)response.StatusCode is >= 300 and < 400; redirects++)
            {
                Assert.IsTrue(redirects < 5);
                var location = new Uri(new Uri("https://localhost"), response.Headers.Location);
                Assert.AreEqual("localhost", location.Host);
                response.Dispose();
                response = await app.Client.GetAsync(location);
            }
            var headers = response.Headers.Concat(response.Content.Headers)
                .Where(x => !new[] { "transfer-encoding", "content-length", "content-encoding", "set-cookie" }.Contains(x.Key.ToLowerInvariant()))
                .ToDictionary(x => x.Key, x => string.Join(", ", x.Value));
            try
            {
                await route.FulfillAsync(new() { Status = (int)response.StatusCode, Headers = headers, BodyBytes = await response.Content.ReadAsByteArrayAsync() });
            }
            finally
            {
                response.Dispose();
            }
        });
        var page = await context.NewPageAsync();
        var errors = new List<string>();
        page.PageError += (_, error) => errors.Add(error);
        await page.GotoAsync("https://localhost/Home/Customer");
        await page.Locator("#SBI").FillAsync("105000001");
        await page.Locator("#BusinessName").FillAsync("Browser Farm");
        await page.Locator("#Address1").FillAsync("Browser Street");
        await page.Locator("#PostCode").FillAsync("LS1 1AA");
        await page.Locator("#CRMCaseReferenceNumber").FillAsync("CRM-browser");
        await page.Locator("#County").FillAsync("1");
        await page.Locator("#Parish").FillAsync("2");
        await page.Locator("#Holding").FillAsync("3");
        await page.Locator("#Add-Parcel").ClickAsync();
        await page.Locator("input[name$='.GridReference']").First.WaitForAsync();
        await page.Locator("#Add-Parcel").ClickAsync();
        await Assertions.Expect(page.Locator("input[name$='.GridReference']")).ToHaveCountAsync(2);
        await page.Locator("#Changes").EvaluateAsync("node => node.value = 'false'");
        await page.Locator("input[name$='.GridReference']").Nth(0).FillAsync("SK12345678");
        await page.Locator("input[name$='.PlaceOfBusiness'][type=checkbox]").Nth(0).CheckAsync();
        Assert.AreEqual("true", (await page.Locator("#Changes").InputValueAsync()).ToLowerInvariant(),
            "Changes to dynamically added inputs must participate in delegated dirty tracking.");
        await page.Locator("input[name$='.GridReference']").Nth(1).FillAsync("SK87654321");
        var indices = await page.Locator("input[name='LandParcels.index']").EvaluateAllAsync<string[]>("nodes => nodes.map(n => n.value)");
        Assert.AreEqual(2, indices.Distinct().Count());
        await page.Locator(".delete-landParcel").Nth(1).ClickAsync();
        Assert.AreEqual("false", (await page.Locator("input[name$='.Active']").Nth(1).InputValueAsync()).ToLowerInvariant());
        Assert.AreEqual("true", (await page.Locator("input[name$='.Active']").Nth(0).InputValueAsync()).ToLowerInvariant());
        Assert.IsFalse(await page.Locator("input[name$='.GridReference']").Nth(1).IsVisibleAsync());
        Assert.AreEqual("true", (await page.Locator("#Changes").InputValueAsync()).ToLowerInvariant());
        Assert.IsTrue(await page.EvaluateAsync<bool>("typeof $.validator === 'function' && $('form').data('validator') !== undefined"));
        await page.Locator("#BusinessName").FillAsync("");
        Assert.IsFalse(await page.EvaluateAsync<bool>("$('form').valid()"), "Required-field validation still works after AJAX validation rebind.");
        await page.Locator("#BusinessName").FillAsync("Browser Farm");
        Assert.IsTrue(await page.EvaluateAsync<bool>("$('form').valid()"));
        // The historical custom grid validator has no client adapter; its regex remains server-only.
        var dialogs = new List<string>();
        var acceptDialogs = false;
        page.Dialog += async (_, dialog) =>
        {
            dialogs.Add(dialog.Message);
            if (acceptDialogs)
                await dialog.AcceptAsync();
            else
                await dialog.DismissAsync();
        };
        await page.Locator("#backList").ClickAsync();
        Assert.AreEqual("You have made unsaved changes, ignore changes?", dialogs.Single());
        await page.Locator("#deleteCustomer").ClickAsync();
        Assert.AreEqual("Are you sure you want to delete this customer record?", dialogs[1]);
        // Server-only POB business rejection forces a real POST/redisplay without relying on client validation.
        await page.Locator("input[name$='.PlaceOfBusiness'][type=checkbox]").Nth(0).UncheckAsync();
        await page.Locator("button[value=save]").ClickAsync();
        await Assertions.Expect(page.Locator(".validation-summary-errors")).ToContainTextAsync("One POB is required.");
        var rebound = await page.Locator("input[name='LandParcels.index']").EvaluateAllAsync<string[]>("nodes => nodes.map(n => n.value)");
        CollectionAssert.AreEqual(indices, rebound);
        Assert.IsFalse(await page.Locator("input[name$='.GridReference']").Nth(1).IsVisibleAsync());
        await page.Locator("input[name$='.PlaceOfBusiness'][type=checkbox]").Nth(0).CheckAsync();
        await page.Locator("button[value=save]").ClickAsync();
        await page.WaitForLoadStateAsync();
        await Assertions.Expect(page.Locator("h2")).ToHaveTextAsync("CPH Non Subsidy Cases");
        using (var database = app.Context())
        {
            Assert.AreEqual(1, database.Customers.Count());
            Assert.AreEqual(1, database.LandParcels.Count());
            Assert.AreEqual("SK12345678", database.LandParcels.Single().GridReference);
            Assert.AreEqual("m1234", database.Audit.Single().LastUpdatedBy);
        }
        await page.GetByRole(AriaRole.Link, new() { Name = "Update", Exact = true }).ClickAsync();
        await Assertions.Expect(page.Locator("h2")).ToHaveTextAsync("Customer Details");
        await page.Locator("#BusinessName").FillAsync("Updated Browser Farm");
        await page.Locator(".delete-landParcel").ClickAsync();
        await page.Locator("#Add-Parcel").ClickAsync();
        await Assertions.Expect(page.Locator("input[name$='.GridReference']")).ToHaveCountAsync(2);
        await page.Locator("input[name$='.GridReference']").Nth(1).FillAsync("SK22222222");
        await page.Locator("input[name$='.PlaceOfBusiness'][type=checkbox]").Nth(1).CheckAsync();
        await page.Locator("button[value=save]").ClickAsync();
        await Assertions.Expect(page.Locator("h2")).ToHaveTextAsync("CPH Non Subsidy Cases");
        await Assertions.Expect(page.Locator("td").Filter(new() { HasText = "SK22222222" })).ToHaveCountAsync(1);
        var exportPath = await page.GetByRole(AriaRole.Link, new() { Name = "Download Customer Data" }).GetAttributeAsync("href");
        var csv = await app.Client.GetStringAsync(exportPath);
        StringAssert.Contains(csv, "\"Updated Browser Farm\"");
        StringAssert.Contains(csv, "\"SK22222222\"");
        Assert.IsFalse(csv.Contains("SK12345678"));
        using (var database = app.Context())
        {
            Assert.AreEqual(2, database.LandParcels.Count());
            Assert.IsFalse(database.LandParcels.Single(x => x.GridReference == "SK12345678").Active);
            Assert.AreEqual("m1234", database.Audit.Single().LastUpdatedBy);
        }
        await page.GetByRole(AriaRole.Link, new() { Name = "Update", Exact = true }).ClickAsync();
        acceptDialogs = true;
        await page.Locator("#deleteCustomer").ClickAsync();
        await Assertions.Expect(page.Locator("h2")).ToHaveTextAsync("CPH Non Subsidy Cases");
        using (var database = app.Context())
        {
            Assert.AreEqual(0, database.Customers.Count());
            Assert.AreEqual(0, database.LandParcels.Count());
            Assert.AreEqual(0, database.Audit.Count());
        }
        CollectionAssert.AreEqual(Array.Empty<string>(), errors.ToArray(), "No JavaScript runtime errors.");
        CollectionAssert.AreEqual(Array.Empty<string>(), blocked.ToArray(), "All rendered resources remain local.");
    }
}
