using System.Web;
using System.Web.Optimization;

namespace RPA.CPH.NonSubsidy.Web
{
    public class BundleConfig
    {
        // For more information on bundling, visit http://go.microsoft.com/fwlink/?LinkId=301862
        public static void RegisterBundles(BundleCollection bundles)
        {
            bundles.UseCdn = true;

            const string jqueryCdnPath = "https://ajax.googleapis.com/ajax/libs/jquery/1.11.3/jquery.min.js";
            const string jqueryUICdnPath = "http://ajax.googleapis.com/ajax/libs/jqueryui/1.11.4/jquery-ui.min.js";

            bundles.Add(new ScriptBundle("~/bundles/jquery", jqueryCdnPath).Include(
                        "~/Scripts/jquery-{version}.js"));

            bundles.Add(new ScriptBundle("~/bundles/jqueryui", jqueryUICdnPath).Include(
                        "~/Scripts/jquery-ui-{version}.js",
                        "~/Scripts/jquery-migrate-{version}.js"));

            bundles.Add(new ScriptBundle("~/bundles/jqueryval", jqueryUICdnPath).Include(
                        "~/Scripts/jquery.unobtrusive*",
                        "~/Scripts/jquery.validate*"));

            // Use the development version of Modernizr to develop with and learn from. Then, when you're
            // ready for production, use the build tool at http://modernizr.com to pick only the tests you need.
            bundles.Add(new ScriptBundle("~/bundles/modernizr").Include(
                        "~/Scripts/modernizr-*"));

            bundles.Add(new ScriptBundle("~/bundles/bootstrap").Include(
                      "~/Scripts/bootstrap.js",
                      "~/Scripts/respond.js"));

            bundles.Add(new StyleBundle("~/Content/bootstrap").Include(
                        "~/Content/bootstrap.css",
                        "~/Content/bootstrap-theme.css"));

            bundles.Add(new StyleBundle("~/Content/css").Include(
                           "~/Content/site.css"));

            bundles.Add(new StyleBundle("~/govuk/css").Include(
                           //"~/assets/govuk/stylesheets/govuk-template.css",
                           "~/assets/govuk/stylesheets/fonts.css"));
        }
    }
}
